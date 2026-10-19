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
    buffered_amount_low_threshold: u16,
};

assoc: sctp.Association,
local_port: u16,
remote_port: u16,
connection_state: ConnectionState,
dtls_server: bool,
max_message_size: u32,
events: std.Deque(Event) = .empty,

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
            .receive_buffer_size = 4 * 1024 * 1024,
        }),
        .max_message_size = default_max_message_size,
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
}

pub fn nextStreamId(sctp_transport: *const SctpTranport, used_sids: []const u16) error{NoAvailableStreamId}!u16 {
    var sid: u16 = @intFromBool(sctp_transport.dtls_server);
    while (sid < sctp_transport.assoc.outbound_streams) : (sid += 2) {
        if (std.mem.indexOfScalar(u16, used_sids, sid) == null) return sid;
    }
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

pub fn handleRead(sctp_transport: *SctpTranport, data: []const u8, now: i64) ReadError!?sctp.Association.MessageIterator {
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
        .buffered_amount_low_threshold => |stream_id| {
            try sctp_transport.events.pushBack(allocator, .{ .buffered_amount_low_threshold = stream_id });
        },
    };

    return it;
}

pub const AppData = union(enum) {
    open: DataChannel,
    ack: u16,
    message: struct { stream_id: u16, binary: bool, data: []const u8 },
};

pub fn handleAppData(sctp_transport: *SctpTranport, msg: *const sctp.message.UserMessage) std.mem.Allocator.Error!?AppData {
    const allocator = sctp_transport.assoc.allocator;

    switch (msg.ppid) {
        DCEP_PPID => {
            defer allocator.free(msg.data);
            const message = DataChannel.Message.parse(msg.data) catch return null;
            switch (message) {
                .open => {
                    const dc = try DataChannel.init(
                        allocator,
                        message.open.label,
                        message.toParameters(msg.stream_id),
                    );
                    return .{ .open = dc };
                },
                .ack => return .{ .ack = msg.stream_id },
            }
        },
        TEXT_MESSAGE_PPID,
        EMPTY_TEXT_MESSAGE_PPID,
        BINARY_MESSAGE_PPID,
        EMPTY_BINRAY_MESSAGE_PPID,
        => {
            const empty_data = msg.ppid == EMPTY_TEXT_MESSAGE_PPID or msg.ppid == EMPTY_BINRAY_MESSAGE_PPID;
            defer if (empty_data) allocator.free(msg.data);
            return .{ .message = .{
                .stream_id = msg.stream_id,
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

pub fn resetStreams(sctp_transport: *SctpTranport, stream_ids: []const u16, flags: DataChannel.StreamResetFlag) void {
    _ = sctp_transport;
    _ = stream_ids;
    _ = flags;
}
