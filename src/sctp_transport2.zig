const std = @import("std");
const sctp = @import("sctp2");

const DataChannel = @import("data_channel.zig");
const DtlsTransport = @import("dtls_transport.zig");
const SctpTranport = @This();

const Logger = std.log.scoped(.sctp_transport);

pub const DCEP_PPID: u32 = 50;
pub const TEXT_MESSAGE_PPID: u32 = 51;
pub const BINARY_MESSAGE_PPID: u32 = 53;
pub const EMPTY_TEXT_MESSAGE_PPID: u32 = 56;
pub const EMPTY_BINRAY_MESSAGE_PPID: u32 = 57;

pub const ConnectionState = enum(u8) { new, connecting, connected, closed };

pub const InitConfig = struct {
    local_port: u16,
    remote_port: u16,
};

pub const Event = union(enum) {
    connection_state: ConnectionState,
    data_channel: *DataChannel,
    data_channel_open: *DataChannel,
    data_channel_close: *DataChannel,
    data_channel_message: struct {
        channel: *DataChannel,
        message: union(enum) {
            text: []const u8,
            binary: []const u8,
        },
    },
};

assoc: sctp.Association,
local_port: u16,
remote_port: u16,
connection_state: ConnectionState,
dtls_server: bool,
max_message_size: u32,
data_channels: std.ArrayList(*DataChannel),
sid_to_data_channel: std.AutoHashMapUnmanaged(u16, *DataChannel),
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
    for (sctp_transport.data_channels.items) |data_channel| {
        data_channel.deinit(allocator);
        allocator.destroy(data_channel);
    }
    sctp_transport.data_channels.deinit(allocator);
    sctp_transport.assoc.deinit();
    sctp_transport.events.deinit(allocator);
}

pub fn addDataChannel(sctp_transport: *SctpTranport, label: []const u8, params: DataChannel.Parameters) !*DataChannel {
    const data_channel = try sctp_transport.newDataChannel(label, params);
    errdefer sctp_transport.deleteDataChannel(data_channel);

    if (sctp_transport.connection_state == .connected) {
        try sctp_transport.generateStreamIdForChannel(data_channel);
        try sctp_transport.sendOpenChannelMessage(data_channel);
    }

    return data_channel;
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
        data_channel.ready_state = .closed;
        sctp_transport.deleteDataChannel(data_channel);
        return;
    };
    try sctp_transport.resetStreams(&.{sid}, .{ .outgoing = true });
    data_channel.ready_state = .closing;
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

            var i: usize = 0;
            while (i < sctp_transport.data_channels.items.len) {
                const data_channel = sctp_transport.data_channels.items[i];
                const failed = blk: {
                    sctp_transport.generateStreamIdForChannel(data_channel) catch |err| {
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
                    data_channel.ready_state = .closed;
                    try sctp_transport.events.pushBack(sctp_transport.assoc.allocator, .{ .data_channel_close = data_channel });
                    sctp_transport.deleteDataChannel(data_channel);
                } else {
                    i += 1;
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

pub fn deleteDataChannel(sctp_transport: *SctpTranport, data_channel: *DataChannel) void {
    if (data_channel.id) |sid| {
        _ = sctp_transport.sid_to_data_channel.remove(sid);
    }

    for (sctp_transport.data_channels.items, 0..) |item, index| {
        if (item == data_channel) {
            _ = sctp_transport.data_channels.swapRemove(index);
            break;
        }
    }

    const allocator = sctp_transport.assoc.allocator;
    data_channel.deinit(allocator);
    allocator.destroy(data_channel);
}

fn newDataChannel(sctp_transport: *SctpTranport, label: []const u8, params: DataChannel.Parameters) !*DataChannel {
    const allocator = sctp_transport.assoc.allocator;
    const data_channel = try allocator.create(DataChannel);
    errdefer allocator.destroy(data_channel);
    data_channel.* = try .init(allocator, label, params);
    errdefer data_channel.deinit(allocator);

    try sctp_transport.data_channels.append(allocator, data_channel);
    return data_channel;
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
                    const data_channel = try sctp_transport.newDataChannel(
                        message.open.label,
                        message.toParameters(stream_id),
                    );
                    errdefer sctp_transport.deleteDataChannel(data_channel);

                    try sctp_transport.putDataChannel(stream_id, data_channel);
                    try sctp_transport.sendAckChannelMessage(data_channel);
                    try sctp_transport.events.pushBack(allocator, .{ .data_channel = data_channel });
                    data_channel.ready_state = .open;
                    try sctp_transport.events.pushBack(allocator, .{ .data_channel_open = data_channel });
                },
                .ack => if (sctp_transport.getDataChannelBySid(stream_id)) |data_channel| {
                    data_channel.ready_state = .open;
                    try sctp_transport.events.pushBack(allocator, .{ .data_channel_open = data_channel });
                },
            }
        },
        TEXT_MESSAGE_PPID,
        EMPTY_TEXT_MESSAGE_PPID,
        BINARY_MESSAGE_PPID,
        EMPTY_BINRAY_MESSAGE_PPID,
        => if (sctp_transport.getDataChannelBySid(stream_id)) |data_channel| {
            var event = Event{
                .data_channel_message = .{
                    .channel = data_channel,
                    .message = undefined,
                },
            };

            event.data_channel_message.message =
                if (ppid == TEXT_MESSAGE_PPID)
                    .{ .text = data }
                else if (ppid == EMPTY_TEXT_MESSAGE_PPID)
                    .{ .text = "" }
                else if (ppid == EMPTY_BINRAY_MESSAGE_PPID)
                    .{ .binary = &.{} }
                else
                    .{ .binary = data };

            try sctp_transport.events.pushBack(allocator, event);
        },
        else => Logger.debug("Received data with unknown ppid: {}", .{ppid}),
    }
}

fn generateStreamIdForChannel(self: *SctpTranport, data_channel: *DataChannel) !void {
    const sid = try nextStreamId(self);
    try self.sid_to_data_channel.put(self.assoc.allocator, sid, data_channel);
    data_channel.id = sid;
}

fn nextStreamId(sctp_transport: *SctpTranport) !u16 {
    var sid: u16 = @intFromBool(sctp_transport.dtls_server);
    while (true) {
        if (sid >= sctp_transport.assoc.outbound_streams) return error.NoAvailableStreamId;
        if (!sctp_transport.sid_to_data_channel.contains(sid)) return sid;
        sid += 2;
    }
}

fn getDataChannelBySid(self: *SctpTranport, sid: u16) ?*DataChannel {
    return self.sid_to_data_channel.get(sid);
}

fn putDataChannel(self: *SctpTranport, sid: u16, data_channel: *DataChannel) !void {
    return self.sid_to_data_channel.put(self.assoc.allocator, sid, data_channel);
}

test "abcd" {
    std.debug.print("SCTP Transport:    {}\n", .{@sizeOf(SctpTranport)});
    std.debug.print("Arr:               {}\n", .{@sizeOf(std.ArrayList(*DataChannel))});
    std.debug.print("DC:                {}\n", .{@sizeOf(DataChannel)});
    std.debug.print("Hash:              {}\n", .{@sizeOf(std.AutoHashMap(u16, *DataChannel))});
    std.debug.print("Hash Unm:          {}\n", .{@sizeOf(std.AutoHashMapUnmanaged(u16, *DataChannel))});
}
