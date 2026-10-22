const std = @import("std");
const sctp = @import("sctp");

const DataChannel = @import("internal_data_channel.zig");
const DtlsTransport = @import("dtls_transport.zig");
const SctpTranport = @This();

const Logger = std.log.scoped(.sctp_transport);

const DCEP_PPID: u32 = 50;
const TEXT_MESSAGE_PPID: u32 = 51;
const BINARY_MESSAGE_PPID: u32 = 53;
const EMPTY_TEXT_MESSAGE_PPID: u32 = 56;
const EMPTY_BINRAY_MESSAGE_PPID: u32 = 57;

pub const ConnectionState = enum(u8) { new, connecting, connected, closed };

pub const default_max_message_size = 65536;

pub const ReadError = error{InvalidPacket} || std.mem.Allocator.Error;
pub const WriteError = error{AssocNotConnected} || std.mem.Allocator.Error;

pub const InitConfig = struct {
    local_port: u16,
    remote_port: u16,
    random: std.Random,
};

pub const Event = union(enum) {
    connection_state: ConnectionState,
    buffered_amount_low_threshold: DataChannel.ChannelId,
    channel_closing: DataChannel.ChannelId,
    channel_closed: DataChannel.ChannelId,
};

const Stream = struct {
    channel_id: DataChannel.ChannelId,
    state: enum { open, closing, closed } = .open,
    outgoing_reset: bool = false,
    incoming_reset: bool = false,
};

assoc: sctp.Association,
local_port: u16,
remote_port: u16,
connection_state: ConnectionState,
dtls_server: bool,
max_message_size: u32,
events: std.Deque(Event),
streams: std.AutoHashMapUnmanaged(u16, Stream),
released_streams: std.ArrayList(u16),

pub fn init(allocator: std.mem.Allocator, init_config: InitConfig) SctpTranport {
    return .{
        .connection_state = .new,
        .local_port = init_config.local_port,
        .remote_port = init_config.remote_port,
        .dtls_server = true,
        .assoc = .init(allocator, .{
            .source_port = init_config.local_port,
            .dest_port = init_config.remote_port,
            .random = init_config.random,
            .supported_extensions = .{
                .stream_reconfiguration = true, // data channel close support
            },
        }),
        .max_message_size = default_max_message_size,
        .events = .empty,
        .streams = .empty,
        .released_streams = .empty,
    };
}

pub fn connect(sctp_transport: *SctpTranport, dtls_client: bool) !void {
    if (sctp_transport.connection_state != .new) return;

    sctp_transport.connection_state = .connecting;
    sctp_transport.assoc.source_port = sctp_transport.local_port;
    sctp_transport.assoc.dest_port = sctp_transport.remote_port;
    sctp_transport.dtls_server = dtls_client;

    try sctp_transport.assoc.connect();
}

pub fn close(sctp_transport: *SctpTranport) void {
    switch (sctp_transport.connection_state) {
        .connecting, .connected => {
            sctp_transport.connection_state = .closed;
            sctp_transport.streams.clearRetainingCapacity();
            sctp_transport.released_streams.clearRetainingCapacity();
            sctp_transport.assoc.shutdown() catch return;
        },
        else => {},
    }
}

pub fn deinit(sctp_transport: *SctpTranport) void {
    const allocator = sctp_transport.assoc.allocator;
    sctp_transport.close();
    sctp_transport.assoc.deinit();
    sctp_transport.events.deinit(allocator);
    sctp_transport.streams.deinit(allocator);
    sctp_transport.released_streams.deinit(allocator);
}

pub const OpenStreamError = error{NoAvailableStreamId} || std.mem.Allocator.Error;

pub fn openStream(sctp_transport: *SctpTranport, channel_id: DataChannel.ChannelId, buffer_threshold: u32) OpenStreamError!u16 {
    try sctp_transport.streams.ensureUnusedCapacity(sctp_transport.assoc.allocator, 1);
    const sid = try sctp_transport.nextStreamId();
    try sctp_transport.setDataChannelBufferedAmountLowThreshold(sid, buffer_threshold);
    sctp_transport.streams.putAssumeCapacity(sid, .{ .channel_id = channel_id });
    return sid;
}

pub fn acceptStream(sctp_transport: *SctpTranport, dc: *const DataChannel, channel_id: DataChannel.ChannelId) WriteError!void {
    try sctp_transport.streams.ensureUnusedCapacity(sctp_transport.assoc.allocator, 1);
    try sctp_transport.handleWrite(dc.writeAckMessage());
    sctp_transport.streams.putAssumeCapacity(dc.id.?, .{ .channel_id = channel_id });
}

pub fn closeStream(sctp_transport: *SctpTranport, stream_id: u16) std.mem.Allocator.Error!void {
    const stream = sctp_transport.streams.getPtr(stream_id) orelse return;
    if (stream.state != .open) return;

    sctp_transport.assoc.resetStreams(&.{stream_id}, .{ .outgoing = true, .incoming = false }) catch |err| switch (err) {
        // The stream cannot be reset, keep it reserved so its id is never reused.
        error.UnsupportedExtension => return sctp_transport.markClosed(stream),
        error.TooManyStreams => unreachable,
        else => |e| return e,
    };
    stream.state = .closing;
}

fn markClosed(sctp_transport: *SctpTranport, stream: *Stream) std.mem.Allocator.Error!void {
    if (stream.state == .closed) return;
    try sctp_transport.events.pushBack(sctp_transport.assoc.allocator, .{ .channel_closed = stream.channel_id });
    stream.state = .closed;
}

fn handleStreamReset(sctp_transport: *SctpTranport, stream_id: u16, event: sctp.Association.Event) std.mem.Allocator.Error!void {
    const stream = sctp_transport.streams.getPtr(stream_id) orelse return;
    switch (event) {
        .incoming_stream_reset => {
            stream.incoming_reset = true;
            if (stream.state == .open) {
                try sctp_transport.events.pushBack(sctp_transport.assoc.allocator, .{ .channel_closing = stream.channel_id });
                try sctp_transport.closeStream(stream_id);
            }
        },
        .outgoing_stream_reset => stream.outgoing_reset = true,
        .outgoing_stream_reset_failed => {
            Logger.debug("Failed to reset outgoing stream {}", .{stream_id});
            return sctp_transport.markClosed(stream);
        },
        else => unreachable,
    }

    if (stream.incoming_reset and stream.outgoing_reset) {
        // Messages received before the reset may still be pending in the iterator, the stream is
        // released once it's drained.
        try sctp_transport.released_streams.append(sctp_transport.assoc.allocator, stream_id);
        try sctp_transport.markClosed(stream);
    }
}

fn releaseStreams(sctp_transport: *SctpTranport) void {
    for (sctp_transport.released_streams.items) |sid| _ = sctp_transport.streams.remove(sid);
    sctp_transport.released_streams.clearRetainingCapacity();
}

fn nextStreamId(sctp_transport: *const SctpTranport) error{NoAvailableStreamId}!u16 {
    var sid: u16 = @intFromBool(sctp_transport.dtls_server);
    while (sid < sctp_transport.assoc.outbound_streams and sctp_transport.streams.contains(sid)) : (sid += 2) {}
    if (sid < sctp_transport.assoc.outbound_streams) return sid;
    return error.NoAvailableStreamId;
}

pub fn bufferedAmount(sctp_transport: *SctpTranport, stream_id: u16) u32 {
    return sctp_transport.assoc.bufferedAmount(stream_id) orelse 0;
}

pub fn setDataChannelBufferedAmountLowThreshold(sctp_transport: *SctpTranport, stream_id: u16, threshold: u32) std.mem.Allocator.Error!void {
    try sctp_transport.assoc.setBufferedAmountLowThreshold(stream_id, threshold);
}

pub fn handleWrite(sctp_transport: *SctpTranport, msg: sctp.message.UserMessage) WriteError!void {
    if (sctp_transport.connection_state != .connected) return error.AssocNotConnected;

    sctp_transport.assoc.handleWrite(msg.data, .{
        .ppid = msg.ppid,
        .stream_id = msg.stream_id,
        .unordered = msg.unordered,
    }) catch |err| switch (err) {
        error.InvalidState => return error.AssocNotConnected,
        else => |e| return e,
    };
}

pub fn handleTimeout(sctp_transport: *SctpTranport, now: i64) std.mem.Allocator.Error!void {
    try sctp_transport.assoc.handleTimeout(now);
}

pub const MessageIterator = struct {
    sctp_it: sctp.Association.MessageIterator,
    transport: *SctpTranport,

    pub fn next(it: *MessageIterator) std.mem.Allocator.Error!?AppData {
        while (it.sctp_it.next()) |msg| {
            if (try it.transport.handleAppData(&msg)) |app_data| return app_data;
        }
        it.transport.releaseStreams();
        return null;
    }
};

pub fn handleRead(sctp_transport: *SctpTranport, data: []const u8, now: i64) ReadError!?MessageIterator {
    switch (sctp_transport.connection_state) {
        .new, .closed => return null,
        else => {},
    }
    const allocator = sctp_transport.assoc.allocator;

    const it = try sctp_transport.assoc.handleRead(data, now);
    while (sctp_transport.assoc.pollEvent()) |event| switch (event) {
        .comm_up => {
            sctp_transport.connection_state = .connected;
            try sctp_transport.events.pushBack(allocator, .{ .connection_state = .connected });
        },
        .comm_down => {
            Logger.debug("sctp association down", .{});
            sctp_transport.connection_state = .closed;
            try sctp_transport.events.pushBack(allocator, .{ .connection_state = .closed });
        },
        .buffered_amount_low_threshold => |stream_id| if (sctp_transport.streams.get(stream_id)) |stream| {
            try sctp_transport.events.pushBack(allocator, .{ .buffered_amount_low_threshold = stream.channel_id });
        },
        .outgoing_stream_reset,
        .outgoing_stream_reset_failed,
        .incoming_stream_reset,
        => |stream_id| if (stream_id) |sid| {
            try sctp_transport.handleStreamReset(sid, event);
        } else {
            Logger.debug("Ignoring reset of all streams", .{});
        },
    };

    const sctp_it = it orelse {
        sctp_transport.releaseStreams();
        return null;
    };
    return .{ .sctp_it = sctp_it, .transport = sctp_transport };
}

pub const AppData = union(enum) {
    open: DataChannel,
    ack: DataChannel.ChannelId,
    message: struct { channel_id: DataChannel.ChannelId, binary: bool, data: []const u8 },
};

fn handleAppData(sctp_transport: *SctpTranport, msg: *const sctp.message.UserMessage) std.mem.Allocator.Error!?AppData {
    const allocator = sctp_transport.assoc.allocator;

    switch (msg.ppid) {
        DCEP_PPID => {
            defer allocator.free(msg.data);
            const message = DataChannel.Message.parse(msg.data) catch return null;
            switch (message) {
                .open => {
                    if (sctp_transport.streams.contains(msg.stream_id)) {
                        Logger.debug("Ignoring DCEP open on stream {} already in use", .{msg.stream_id});
                        return null;
                    }
                    const dc = try DataChannel.init(
                        allocator,
                        message.open.label,
                        message.toParameters(msg.stream_id),
                    );
                    return .{ .open = dc };
                },
                .ack => if (sctp_transport.streams.get(msg.stream_id)) |stream| return .{ .ack = stream.channel_id },
            }
        },
        TEXT_MESSAGE_PPID,
        EMPTY_TEXT_MESSAGE_PPID,
        BINARY_MESSAGE_PPID,
        EMPTY_BINRAY_MESSAGE_PPID,
        => {
            const stream = sctp_transport.streams.get(msg.stream_id) orelse {
                allocator.free(msg.data);
                return null;
            };
            const empty_data = msg.ppid == EMPTY_TEXT_MESSAGE_PPID or msg.ppid == EMPTY_BINRAY_MESSAGE_PPID;
            defer if (empty_data) allocator.free(msg.data);
            return .{ .message = .{
                .channel_id = stream.channel_id,
                .binary = msg.ppid == BINARY_MESSAGE_PPID or msg.ppid == EMPTY_BINRAY_MESSAGE_PPID,
                .data = if (empty_data) &.{} else msg.data,
            } };
        },
        else => {
            Logger.debug("Received data with unknown ppid: {}", .{msg.ppid});
            allocator.free(msg.data);
        },
    }

    return null;
}

pub fn pollTransmit(sctp_transport: *SctpTranport, buffer: []u8, now: i64) !?[]const u8 {
    return sctp_transport.assoc.pollTransmit(buffer, now);
}

pub fn pollTimeout(sctp_transport: *SctpTranport) ?i64 {
    return sctp_transport.assoc.pollTimeout();
}

pub fn pollEvent(sctp_transport: *SctpTranport) ?Event {
    return sctp_transport.events.popFront();
}
