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
    on_event: ?*const fn (sctp_transport: *SctpTranport, event: Event) void = null,
};

pub const Event = union(enum) {
    connection_state: ConnectionState,
    data_channel: *DataChannel,
};

io: std.Io,
assoc: sctp.Association,
local_port: u16,
remote_port: u16,
connection_state: std.atomic.Value(ConnectionState),
dtls_transport: *DtlsTransport,
max_message_size: u32,
max_channels: u16,
data_channels: std.ArrayList(*DataChannel),
sid_to_data_channel: std.AutoHashMap(u16, *DataChannel),
mutex: std.Io.Mutex,
on_event: ?*const fn (sctp_transport: *SctpTranport, event: Event) void,

pub fn init(io: std.Io, allocator: std.mem.Allocator, init_config: InitConfig) SctpTranport {
    return .{
        .io = io,
        .connection_state = .init(.new),
        .local_port = init_config.local_port,
        .remote_port = init_config.remote_port,
        .dtls_transport = undefined,
        .assoc = .init(allocator, .{
            .source_port = init_config.local_port,
            .dest_port = init_config.remote_port,
        }),
        .max_message_size = 0,
        .max_channels = std.math.maxInt(u16),
        .data_channels = .empty,
        .sid_to_data_channel = .init(allocator),
        .on_event = init_config.on_event,
        .mutex = .init,
    };
}

pub fn connect(sctp_transport: *SctpTranport, dtls_transport: *DtlsTransport) !void {
    if (@cmpxchgWeak(
        ConnectionState,
        &sctp_transport.connection_state.raw,
        .new,
        .connecting,
        .seq_cst,
        .seq_cst,
    )) |_| return;

    sctp_transport.assoc.source_port = sctp_transport.local_port;
    sctp_transport.assoc.dest_port = sctp_transport.remote_port;
    sctp_transport.dtls_transport = dtls_transport;

    try sctp_transport.assoc.connect();
    const now = std.Io.Timestamp.now(sctp_transport.io, .awake).toMilliseconds();
    try sctp_transport.drainAssoc(now);
}

pub fn close(sctp_transport: *SctpTranport) void {
    switch (sctp_transport.connection_state.load(.seq_cst)) {
        .connecting, .connected => {
            sctp_transport.connection_state.store(.closed, .seq_cst);
            // sctp_transport.assoc.close();
        },
        else => {},
    }
}

pub fn deinit(sctp_transport: *SctpTranport, allocator: std.mem.Allocator) void {
    sctp_transport.close();
    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    sctp_transport.sid_to_data_channel.deinit();
    for (sctp_transport.data_channels.items) |data_channel| {
        data_channel.deinit(allocator);
        allocator.destroy(data_channel);
    }
    sctp_transport.data_channels.deinit(allocator);
    sctp_transport.assoc.deinit();
}

pub fn sendData(sctp_transport: *SctpTranport, data: []const u8, config: sctp.message.UserMessageConfig) !void {
    // try sctp_transport.mutex.lock(sctp_transport.io);
    // defer sctp_transport.mutex.unlock(sctp_transport.io);
    try sctp_transport.assoc.handleWrite(data, config);
    const now = std.Io.Timestamp.now(sctp_transport.io, .awake).toMilliseconds();
    try sctp_transport.drainTransmits(now);
}

pub fn handleRead(sctp_transport: *SctpTranport, data: []const u8) !void {
    switch (sctp_transport.connection_state.load(.seq_cst)) {
        .new, .closed => return,
        else => {},
    }

    Logger.debug("received sctp data of length: {}", .{data.len});
    const now = std.Io.Timestamp.now(sctp_transport.io, .awake).toMilliseconds();
    // try sctp_transport.mutex.lock(sctp_transport.io);
    // defer sctp_transport.mutex.unlock(sctp_transport.io);
    try sctp_transport.assoc.handleRead(data, now);
    try sctp_transport.drainAssoc(now);
}

pub fn addDataChannel(
    sctp_transport: *SctpTranport,
    allocator: std.mem.Allocator,
    label: []const u8,
    params: DataChannel.Parameters,
) !*DataChannel {
    const data_channel = try sctp_transport.newDataChannel(allocator, label, params);
    errdefer sctp_transport.deleteDataChannel(data_channel);

    if (sctp_transport.connection_state.load(.seq_cst) == .connected) {
        {
            sctp_transport.mutex.lockUncancelable(sctp_transport.io);
            defer sctp_transport.mutex.unlock(sctp_transport.io);
            try sctp_transport.generateStreamIdForChannel(data_channel);
        }
        try sctp_transport.sendOpenChannelMessage(data_channel);
    }

    return data_channel;
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
    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    sctp_transport.deleteChannelLocked(data_channel);
}

fn drainAssoc(sctp_transport: *SctpTranport, now: i64) !void {
    while (sctp_transport.assoc.pollEvent()) |event| switch (event) {
        .comm_up => {
            Logger.debug("sctp association up", .{});
            sctp_transport.connection_state.store(.connected, .seq_cst);

            {
                sctp_transport.mutex.lockUncancelable(sctp_transport.io);
                defer sctp_transport.mutex.unlock(sctp_transport.io);
                sctp_transport.max_channels = sctp_transport.assoc.outbound_streams;

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
                        data_channel.setReadyState(.closed);
                        sctp_transport.deleteChannelLocked(data_channel);
                    } else {
                        i += 1;
                    }
                }
            }

            if (sctp_transport.on_event) |on_event| {
                on_event(sctp_transport, .{ .connection_state = .connected });
            }
        },
        .comm_down => {
            Logger.debug("sctp association down", .{});
            sctp_transport.connection_state.store(.closed, .seq_cst);
            if (sctp_transport.on_event) |on_event| {
                on_event(sctp_transport, .{ .connection_state = .closed });
            }
        },
        .message => |message| {
            defer message.deinit(sctp_transport.dtls_transport.allocator);
            try sctp_transport.handleAppData(message.ppid, message.stream_id, message.data);
        },
        .release => |msg| {
            _ = msg;
        },
    };

    try sctp_transport.drainTransmits(now);
    const deadline = sctp_transport.assoc.pollTimeout() orelse return;
    _ = deadline;
}

fn drainTransmits(sctp_transport: *SctpTranport, now: i64) !void {
    var buffer: [1500]u8 = undefined;
    while (sctp_transport.assoc.pollTransmits(&buffer, now)) |d| {
        try sctp_transport.dtls_transport.sendData(d);
    }
}

fn newDataChannel(sctp_transport: *SctpTranport, allocator: std.mem.Allocator, label: []const u8, params: DataChannel.Parameters) !*DataChannel {
    const data_channel = try allocator.create(DataChannel);
    errdefer allocator.destroy(data_channel);
    data_channel.* = try .init(allocator, label, sctp_transport, params);
    errdefer data_channel.deinit(allocator);

    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    try sctp_transport.data_channels.append(allocator, data_channel);
    return data_channel;
}

fn sendOpenChannelMessage(sctp_transport: *SctpTranport, data_channel: *DataChannel) !void {
    const buffer = try sctp_transport.dtls_transport.createPacket();
    defer sctp_transport.dtls_transport.destroyPacket(buffer);

    const message = try data_channel.writeOpenMessage(buffer);
    try sctp_transport.sendData(message, .{
        .ppid = DCEP_PPID,
        .stream_id = data_channel.id.?,
    });
}

fn sendAckChannelMessage(sctp_transport: *SctpTranport, data_channel: *DataChannel) !void {
    try sctp_transport.sendData(&[_]u8{@intFromEnum(DataChannel.MessageType.ack)}, .{
        .ppid = DCEP_PPID,
        .stream_id = data_channel.id.?,
    });
}

// fn handleNotification(sctp_transport: *SctpTranport, data: []u8) !void {
//     const notif: *sctp.Notification = @ptrCast(@alignCast(data.ptr));
//     Logger.debug("handle notification: {s}", .{@tagName(notif.header.type)});

//     switch (notif.header.type) {
//         .assoc_change => try sctp_transport.handleAssocChange(&notif.assoc_change),
//         .shutdown => sctp_transport.close(),
//         .stream_reset => try sctp_transport.handleStreamReset(&notif.stream_reset, data),
//         else => {},
//     }
// }

// fn handleStreamReset(sctp_transport: *SctpTranport, notif: *const sctp.Notification.StreamResetEvent, data: []const u8) !void {
//     if (notif.flags.denied or notif.flags.failed) {
//         Logger.warn("stream reset denied or failed", .{});
//         return;
//     }

//     var r = std.Io.Reader.fixed(data[@sizeOf(sctp.Notification.StreamResetEvent)..]);
//     while (r.takeInt(u16, .native)) |sid| {
//         const data_channel = sctp_transport.getDataChannelBySid(sid) orelse continue;

//         if (notif.flags.incoming_ssn and data_channel.ready_state != .closing) {
//             sctp_transport.resetStreams(&.{sid}, .{ .outgoing = true }) catch |err| {
//                 Logger.warn("Failed to mirror stream reset for sid {}: {}\n", .{ sid, err });
//             };
//         }

//         data_channel.setReadyState(.closed);
//         sctp_transport.deleteDataChannel(data_channel);
//     } else |_| {}
// }

fn handleAppData(sctp_transport: *SctpTranport, ppid: u32, stream_id: u16, data: []u8) !void {
    const allocator = sctp_transport.dtls_transport.allocator;

    switch (ppid) {
        DCEP_PPID => {
            const message = try DataChannel.Message.parse(data);
            switch (message) {
                .open => {
                    const data_channel = try sctp_transport.newDataChannel(
                        allocator,
                        message.open.label,
                        message.toParameters(stream_id),
                    );
                    errdefer sctp_transport.deleteDataChannel(data_channel);

                    try sctp_transport.putDataChannel(stream_id, data_channel);
                    try sctp_transport.sendAckChannelMessage(data_channel);
                    if (sctp_transport.on_event) |on_event| {
                        on_event(sctp_transport, .{ .data_channel = data_channel });
                    }
                    data_channel.setReadyState(.open);
                },
                .ack => if (sctp_transport.getDataChannelBySid(stream_id)) |data_channel| {
                    data_channel.setReadyState(.open);
                },
            }
        },
        TEXT_MESSAGE_PPID,
        EMPTY_TEXT_MESSAGE_PPID,
        BINARY_MESSAGE_PPID,
        EMPTY_BINRAY_MESSAGE_PPID,
        => if (sctp_transport.getDataChannelBySid(stream_id)) |data_channel| {
            if (data_channel.on_event) |on_event| {
                const event: DataChannel.Event =
                    if (ppid == TEXT_MESSAGE_PPID)
                        .{ .text_message = data }
                    else if (ppid == EMPTY_TEXT_MESSAGE_PPID)
                        .{ .text_message = "" }
                    else if (ppid == EMPTY_BINRAY_MESSAGE_PPID)
                        .{ .binary_message = &.{} }
                    else
                        .{ .binary_message = data };
                on_event(data_channel.userdata, data_channel, event);
            }
        },
        else => Logger.debug("Received data with unknown ppid: {}", .{ppid}),
    }
}

fn generateStreamIdForChannel(sctp_transport: *SctpTranport, data_channel: *DataChannel) !void {
    const sid = try nextStreamId(sctp_transport);
    try sctp_transport.sid_to_data_channel.put(sid, data_channel);
    data_channel.id = sid;
}

fn nextStreamId(sctp_transport: *SctpTranport) !u16 {
    var sid: u16 = if (sctp_transport.dtls_transport.getRole() == .client) 0 else 1;
    while (true) {
        if (sid >= sctp_transport.max_channels) return error.NoAvailableStreamId;
        if (!sctp_transport.sid_to_data_channel.contains(sid)) return sid;
        sid += 2;
    }
}

fn deleteChannelLocked(sctp_transport: *SctpTranport, data_channel: *DataChannel) void {
    if (data_channel.id) |sid| {
        _ = sctp_transport.sid_to_data_channel.remove(sid);
    }

    for (sctp_transport.data_channels.items, 0..) |item, index| {
        if (item == data_channel) {
            _ = sctp_transport.data_channels.swapRemove(index);
            break;
        }
    }

    const allocator = sctp_transport.dtls_transport.allocator;
    data_channel.deinit(allocator);
    allocator.destroy(data_channel);
}

fn getDataChannelBySid(sctp_transport: *SctpTranport, sid: u16) ?*DataChannel {
    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    return sctp_transport.sid_to_data_channel.get(sid);
}

fn putDataChannel(sctp_transport: *SctpTranport, sid: u16, data_channel: *DataChannel) !void {
    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    return sctp_transport.sid_to_data_channel.put(sid, data_channel);
}
