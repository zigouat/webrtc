const std = @import("std");
const sctp = @import("sctp2");

const DataChannel = @import("data_channel.zig");
const DtlsTransport = @import("dtls_transport.zig");
const SctpTranport = @This();

const Logger = std.log.scoped(.sctp_transport);

const DCEP_PPID: u32 = 50;
const TEXT_MESSAGE_PPID: u32 = 51;
const BINARY_MESSAGE_PPID: u32 = 53;
const EMPTY_TEXT_MESSAGE_PPID: u32 = 56;
const EMPTY_BINRAY_MESSAGE_PPID: u32 = 57;

pub const ChannelId = u32;

pub const ConnectionState = enum(u8) { new, connecting, connected, closed };

pub const InitConfig = struct {
    local_port: u16,
    remote_port: u16,
};

pub const DataChannelEvent = union(enum) {
    new: ChannelId,
    open: ChannelId,
    close: ChannelId,
    message: struct {
        channel_id: ChannelId,
        binary: bool,
        data: []const u8,
    },
};

pub const Event = union(enum) {
    connection_state: ConnectionState,
    data_channel: DataChannelEvent,
};

assoc: sctp.Association,
local_port: u16,
remote_port: u16,
connection_state: ConnectionState,
dtls_server: bool,
max_message_size: u32,
data_channels: std.ArrayList(DataChannel),
sid_to_data_channel: std.AutoHashMapUnmanaged(u16, u32),
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
        }),
        .max_message_size = 0,
        .data_channels = .empty,
        .sid_to_data_channel = .empty,
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
            // sctp_transport.assoc.close();
        },
        else => {},
    }
}

pub fn deinit(sctp_transport: *SctpTranport) void {
    const allocator = sctp_transport.assoc.allocator;
    sctp_transport.close();
    sctp_transport.sid_to_data_channel.deinit(allocator);
    for (sctp_transport.data_channels.items) |*data_channel| data_channel.deinit(allocator);
    sctp_transport.data_channels.deinit(allocator);
    sctp_transport.assoc.deinit();
    sctp_transport.events.deinit(allocator);
}

pub fn addDataChannel(sctp_transport: *SctpTranport, label: []const u8, params: DataChannel.Parameters) !ChannelId {
    const channel_id = try sctp_transport.newDataChannel(label, params);
    errdefer {
        sctp_transport.markeDataChannelDeleted(channel_id);
        // it's safe to delete the channel here because we didn't yet provide the id to the user.
        sctp_transport.data_channels.swapRemove(channel_id);
    }

    const data_channel = sctp_transport.getDataChannel(channel_id);
    if (sctp_transport.connection_state == .connected) {
        try sctp_transport.generateStreamIdForChannel(channel_id);
        try sctp_transport.sendOpenChannelMessage(data_channel);
    }

    return channel_id;
}

pub fn sendDataChannelMessage(sctp_transport: *SctpTranport, data_channel: *DataChannel, data: []const u8, binary: bool) !void {
    const ppid = if (binary and data.len == 0)
        EMPTY_BINRAY_MESSAGE_PPID
    else if (binary)
        BINARY_MESSAGE_PPID
    else if (data.len == 0)
        EMPTY_TEXT_MESSAGE_PPID
    else
        TEXT_MESSAGE_PPID;

    const copy = try sctp_transport.assoc.allocator.dupe(u8, data);
    errdefer sctp_transport.assoc.allocator.free(copy);

    try sctp_transport.handleWrite(copy, .{
        .ppid = ppid,
        .stream_id = data_channel.id.?,
    });
}

pub fn closeDataChannel(sctp_transport: *SctpTranport, data_channel: *DataChannel) !void {
    if (data_channel.ready_state == .closing or data_channel.ready_state == .closed) return;

    const sid = data_channel.id orelse {
        sctp_transport.markeDataChannelDeleted(data_channel);
        return;
    };
    try sctp_transport.resetStreams(&.{sid}, .{ .outgoing = true });
    data_channel.ready_state = .closing;
}

pub fn getDataChannel(self: *SctpTranport, id: ChannelId) *DataChannel {
    std.debug.assert(id < self.data_channels.items.len);
    return &self.data_channels.items[id];
}

pub fn handleWrite(sctp_transport: *SctpTranport, data: []const u8, config: sctp.message.UserMessageConfig) !void {
    const buffer = try sctp_transport.assoc.allocator.dupe(u8, data);
    errdefer sctp_transport.assoc.allocator.free(buffer);
    try sctp_transport.assoc.handleWrite(buffer, config);
}

pub fn handleTimeout(sctp_transport: *SctpTranport, now: i64) !void {
    try sctp_transport.assoc.handleTimeout(now);
}

pub fn handleRead(sctp_transport: *SctpTranport, data: []const u8, now: i64) !void {
    switch (sctp_transport.connection_state) {
        .new, .closed => return,
        else => {},
    }
    try sctp_transport.assoc.handleRead(data, now);

    while (sctp_transport.assoc.pollEvent()) |event| switch (event) {
        .comm_up => {
            Logger.debug("sctp association up", .{});
            sctp_transport.connection_state = .connected;

            var channel_id: u32 = 0;
            while (channel_id < sctp_transport.data_channels.items.len) {
                const data_channel = sctp_transport.getDataChannel(channel_id);
                const failed = blk: {
                    sctp_transport.generateStreamIdForChannel(channel_id) catch |err| {
                        Logger.warn("Failed to generate stream ID for data channel: {}\n", .{err});
                        break :blk true;
                    };
                    sctp_transport.sendOpenChannelMessage(data_channel) catch |err| {
                        Logger.warn("Failed to send open message for data channel: {}\n", .{err});
                        break :blk true;
                    };
                    break :blk false;
                };
                if (failed) {
                    sctp_transport.markeDataChannelDeleted(@intCast(channel_id));
                    try sctp_transport.events.pushBack(sctp_transport.assoc.allocator, .{ .data_channel = .{ .close = channel_id } });
                } else {
                    channel_id += 1;
                }
            }

            try sctp_transport.events.pushBack(sctp_transport.assoc.allocator, .{ .connection_state = .connected });
        },
        .comm_down => {
            Logger.debug("sctp association down", .{});
            sctp_transport.connection_state = .closed;
            try sctp_transport.events.pushBack(sctp_transport.assoc.allocator, .{ .connection_state = .closed });
        },
        .message => |message| {
            try sctp_transport.handleAppData(message.ppid, message.stream_id, message.data);
        },
        .release => |msg| sctp_transport.assoc.allocator.free(msg),
    };
}

pub fn pollTransmits(sctp_transport: *SctpTranport, buffer: []u8, now: i64) ?[]const u8 {
    return sctp_transport.assoc.pollTransmits(buffer, now);
}

pub fn pollTimeout(sctp_transport: *SctpTranport) ?i64 {
    return sctp_transport.assoc.pollTimeout();
}

pub fn pollEvent(sctp_transport: *SctpTranport) ?Event {
    return sctp_transport.events.popFront();
}

pub fn hasDataChannels(sctp_transport: *SctpTranport) bool {
    return sctp_transport.data_channels.items.len > 0;
}

pub fn resetStreams(sctp_transport: *SctpTranport, stream_ids: []const u16, flags: DataChannel.StreamResetFlag) !void {
    _ = sctp_transport;
    _ = stream_ids;
    _ = flags;
    // try sctp_transport.socket.resetStreams(stream_ids, flags);
}

pub fn markeDataChannelDeleted(sctp_transport: *SctpTranport, channel_id: ChannelId) void {
    const data_channel = sctp_transport.getDataChannel(channel_id);

    if (data_channel.id) |sid| {
        _ = sctp_transport.sid_to_data_channel.remove(sid);
    }

    data_channel.ready_state = .closed;
    data_channel.id = null;
    data_channel.deinit(sctp_transport.assoc.allocator);
}

fn newDataChannel(self: *SctpTranport, label: []const u8, params: DataChannel.Parameters) !ChannelId {
    const allocator = self.assoc.allocator;
    try self.data_channels.ensureUnusedCapacity(allocator, 1);

    var data_channel = try DataChannel.init(allocator, label, params);
    errdefer data_channel.deinit(allocator);

    self.data_channels.appendAssumeCapacity(data_channel);
    return @intCast(self.data_channels.items.len - 1);
}

fn sendOpenChannelMessage(self: *SctpTranport, data_channel: *DataChannel) !void {
    var buffer: [1024]u8 = undefined;
    const message = try data_channel.writeOpenMessage(&buffer);
    try self.handleWrite(message, .{
        .ppid = DCEP_PPID,
        .stream_id = data_channel.id.?,
    });
}

fn sendAckChannelMessage(self: *SctpTranport, data_channel: *DataChannel) !void {
    try self.handleWrite(&[_]u8{@intFromEnum(DataChannel.MessageType.ack)}, .{
        .ppid = DCEP_PPID,
        .stream_id = data_channel.id.?,
    });
}

fn handleAppData(sctp_transport: *SctpTranport, ppid: u32, stream_id: u16, data: []u8) !void {
    const allocator = sctp_transport.assoc.allocator;

    switch (ppid) {
        DCEP_PPID => {
            defer allocator.free(data);
            const message = try DataChannel.Message.parse(data);
            switch (message) {
                .open => {
                    try sctp_transport.events.ensureUnusedCapacity(allocator, 2);

                    const channel_id = try sctp_transport.newDataChannel(
                        message.open.label,
                        message.toParameters(stream_id),
                    );
                    errdefer sctp_transport.markeDataChannelDeleted(channel_id);

                    const data_channel = sctp_transport.getDataChannel(channel_id);
                    try sctp_transport.putDataChannel(stream_id, channel_id);
                    try sctp_transport.sendAckChannelMessage(data_channel);

                    data_channel.ready_state = .open;
                    sctp_transport.events.pushBackAssumeCapacity(.{ .data_channel = .{ .new = channel_id } });
                    sctp_transport.events.pushBackAssumeCapacity(.{ .data_channel = .{ .open = channel_id } });
                },
                .ack => if (sctp_transport.getDataChannelBySid(stream_id)) |channel_id| {
                    const data_channel = sctp_transport.getDataChannel(channel_id);
                    data_channel.ready_state = .open;
                    try sctp_transport.events.pushBack(allocator, .{ .data_channel = .{ .open = channel_id } });
                },
            }
        },
        TEXT_MESSAGE_PPID,
        EMPTY_TEXT_MESSAGE_PPID,
        BINARY_MESSAGE_PPID,
        EMPTY_BINRAY_MESSAGE_PPID,
        => if (sctp_transport.getDataChannelBySid(stream_id)) |id| {
            const empty_data = ppid == EMPTY_TEXT_MESSAGE_PPID or ppid == EMPTY_BINRAY_MESSAGE_PPID;
            defer if (empty_data) allocator.free(data);
            try sctp_transport.events.pushBack(allocator, .{
                .data_channel = .{
                    .message = .{
                        .channel_id = id,
                        .binary = ppid == BINARY_MESSAGE_PPID or ppid == EMPTY_BINRAY_MESSAGE_PPID,
                        .data = if (empty_data) &.{} else data,
                    },
                },
            });
        },
        else => Logger.debug("Received data with unknown ppid: {}", .{ppid}),
    }
}

fn generateStreamIdForChannel(self: *SctpTranport, channel_id: ChannelId) !void {
    const sid = try nextStreamId(self);
    try self.sid_to_data_channel.put(self.assoc.allocator, sid, channel_id);
    self.getDataChannel(channel_id).id = sid;
}

fn nextStreamId(sctp_transport: *SctpTranport) !u16 {
    var sid: u16 = @intFromBool(sctp_transport.dtls_server);
    while (true) {
        if (sid >= sctp_transport.assoc.outbound_streams) return error.NoAvailableStreamId;
        if (!sctp_transport.sid_to_data_channel.contains(sid)) return sid;
        sid += 2;
    }
}

fn getDataChannelBySid(self: *SctpTranport, sid: u16) ?ChannelId {
    return self.sid_to_data_channel.get(sid);
}

fn putDataChannel(self: *SctpTranport, sid: u16, channel_id: ChannelId) !void {
    return self.sid_to_data_channel.put(self.assoc.allocator, sid, channel_id);
}
