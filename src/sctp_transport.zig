const std = @import("std");
const sctp = @import("sctp");

const DataChannel = @import("data_channel.zig");
const DtlsTransport = @import("dtls_transport.zig");
const SctpTranport = @This();

const Logger = std.log.scoped(.sctp_transport);

const DCEP_PPID: u32 = 50;
const TEXT_MESSAGE_PPID: u32 = 51;
const BINARY_MESSAGE_PPID: u32 = 53;

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
socket: *sctp.Socket,
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
        .socket = undefined,
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

    sctp_transport.dtls_transport = dtls_transport;
    sctp_transport.socket = try sctp.Socket.create(.{
        .receive_cb = receive_cb,
        .ctx = sctp_transport,
        .non_blocking = true,
        .no_delay = true,
        .enable_stream_reset = true,
    });

    var init_msg = sctp.InitMsg{ .max_instreams = sctp_transport.max_channels, .num_ostreams = sctp_transport.max_channels };
    try sctp_transport.socket.setInitMessage(&init_msg);
    try sctp_transport.socket.subscribe(&[_]sctp.EventType{ .assoc_change, .send_failed, .shutdown, .stream_reset });

    const socket = sctp_transport.socket;
    sctp.registerAddress(sctp_transport);
    errdefer sctp.deregisterAddress(sctp_transport);

    var sock_addr = sctp.SockaddrConn.init(std.mem.nativeToBig(u16, sctp_transport.local_port), sctp_transport);
    try socket.bind(&sock_addr);

    var remote_addr = sctp.SockaddrConn.init(std.mem.nativeToBig(u16, sctp_transport.remote_port), sctp_transport);
    try socket.connect(&remote_addr);
}

pub fn close(sctp_transport: *SctpTranport) void {
    switch (sctp_transport.connection_state.load(.seq_cst)) {
        .connecting, .connected => {
            sctp_transport.connection_state.store(.closed, .seq_cst);
            sctp_transport.socket.close();
        },
        else => {},
    }
}

pub fn deinit(sctp_transport: *SctpTranport, allocator: std.mem.Allocator) void {
    switch (sctp_transport.connection_state.load(.seq_cst)) {
        .connecting, .connected => {
            sctp.deregisterAddress(sctp_transport);
            sctp_transport.socket.close();
        },
        else => {},
    }

    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    for (sctp_transport.data_channels.items) |data_channel| {
        data_channel.deinit(allocator);
        allocator.destroy(data_channel);
    }
    sctp_transport.data_channels.deinit(allocator);
    sctp_transport.sid_to_data_channel.deinit();
}

pub fn sendData(sctp_transport: *SctpTranport, data: []const u8) !void {
    try sctp_transport.dtls_transport.sendData(data);
}

pub fn handleIncomingData(sctp_transport: *SctpTranport, data: []const u8) void {
    switch (sctp_transport.connection_state.load(.seq_cst)) {
        .new, .closed => return,
        else => {},
    }

    Logger.debug("received sctp data of length: {}", .{data.len});
    sctp.connInput(sctp_transport, data);
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

fn receive_cb(
    sock: ?*sctp.Socket,
    addr: sctp.SockstoreConn,
    maybe_data: ?*anyopaque,
    len: usize,
    rcvinfo: sctp.RcvInfo,
    flags: sctp.Flags,
    ulp_info: ?*anyopaque,
) callconv(.c) c_int {
    _ = sock;
    _ = addr;

    const sctp_transport: *SctpTranport = @ptrCast(@alignCast(ulp_info.?));
    const data = @as([*]u8, @ptrCast(@alignCast(maybe_data orelse return 1)))[0..len];

    if (flags.notification) {
        sctp_transport.handleNotification(data) catch |err| {
            Logger.err("Error handling notification: {}\n", .{err});
        };
        return 1;
    }

    const ppid = std.mem.bigToNative(u32, rcvinfo.ppid);
    const stream_id = rcvinfo.sid;

    sctp_transport.handleAppData(ppid, stream_id, data) catch |err| {
        Logger.err("Error handling app data: {}\n", .{err});
    };
    return 1;
}

fn newDataChannel(sctp_transport: *SctpTranport, allocator: std.mem.Allocator, label: []const u8, params: DataChannel.Parameters) !*DataChannel {
    const data_channel = try allocator.create(DataChannel);
    errdefer allocator.destroy(data_channel);
    data_channel.* = try .init(allocator, label, params);
    errdefer data_channel.deinit(allocator);

    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    try sctp_transport.data_channels.append(allocator, data_channel);
    return data_channel;
}

fn sendOpenChannelMessage(sctp_transport: *SctpTranport, data_channel: *DataChannel) !void {
    const buffer = try sctp_transport.dtls_transport.ice_agent.createPacket();
    defer sctp_transport.dtls_transport.ice_agent.destroyPacket(buffer);

    const message = try data_channel.writeOpenMessage(buffer);
    try sctp_transport.socket.send(message, .{
        .ppid = DCEP_PPID,
        .sid = data_channel.id.?,
        .ordered = true,
    });
}

fn sendAckChannelMessage(sctp_transport: *SctpTranport, data_channel: *DataChannel) !void {
    try sctp_transport.socket.send(&[_]u8{@intFromEnum(DataChannel.MessageType.ack)}, .{
        .ppid = DCEP_PPID,
        .sid = data_channel.id.?,
        .ordered = true,
    });
}

fn handleNotification(sctp_transport: *SctpTranport, data: []u8) !void {
    const notif: *sctp.Notification = @ptrCast(@alignCast(data.ptr));
    Logger.debug("handle notification: {s}", .{@tagName(notif.header.type)});

    switch (notif.header.type) {
        .assoc_change => try sctp_transport.handleAssocChange(&notif.assoc_change),
        .shutdown => sctp_transport.close(),
        else => {},
    }
}

fn handleAssocChange(sctp_transport: *SctpTranport, assoc_change: *sctp.Notification.AssocChange) !void {
    switch (assoc_change.state) {
        .COMM_UP => {
            Logger.debug("sctp association up", .{});
            sctp_transport.connection_state.store(.connected, .seq_cst);

            {
                sctp_transport.mutex.lockUncancelable(sctp_transport.io);
                defer sctp_transport.mutex.unlock(sctp_transport.io);
                sctp_transport.max_channels = @min(assoc_change.outbound_streams, assoc_change.inbound_streams);
                for (sctp_transport.data_channels.items) |data_channel| {
                    sctp_transport.generateStreamIdForChannel(data_channel) catch |err| {
                        Logger.err("Failed to generate stream ID for data channel: {}\n", .{err});
                        data_channel.setReadyState(.closed);
                        continue;
                    };
                    try sctp_transport.sendOpenChannelMessage(data_channel);
                }
            }

            if (sctp_transport.on_event) |on_event| {
                on_event(sctp_transport, .{ .connection_state = .connected });
            }
        },
        .COMM_LOST, .SHUTDOWN_COMP, .CANT_STR_ASSOC => {
            Logger.debug("sctp association down", .{});
            sctp_transport.connection_state.store(.closed, .seq_cst);
            if (sctp_transport.on_event) |on_event| {
                on_event(sctp_transport, .{ .connection_state = .closed });
            }
        },
        .RESTART => Logger.warn("sctp association restarted", .{}),
    }
}

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
                    errdefer {
                        data_channel.deinit(allocator);
                        allocator.destroy(data_channel);
                    }
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
        TEXT_MESSAGE_PPID, BINARY_MESSAGE_PPID => if (sctp_transport.getDataChannelBySid(stream_id)) |data_channel| {
            if (data_channel.on_event) |on_event| {
                const event: DataChannel.Event =
                    if (ppid == TEXT_MESSAGE_PPID)
                        .{ .text_message = data }
                    else
                        .{ .binary_message = data };
                on_event(data_channel, event);
            }
        },
        else => {},
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

fn deleteDataChannel(sctp_transport: *SctpTranport, data_channel: *DataChannel) void {
    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);

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

const testing = std.testing;

fn testAssocChange(state: sctp.Notification.AssocChange.State) sctp.Notification.AssocChange {
    return .{
        .type = .assoc_change,
        .flags = 0,
        .length = 0,
        .state = state,
        .err = 0,
        .outbound_streams = 0,
        .inbound_streams = 0,
        .assoc_id = 0,
        ._sac_info = .{},
    };
}

fn newTestSctpTransport() SctpTranport {
    return SctpTranport.init(testing.io, testing.allocator, .{
        .local_port = 5000,
        .remote_port = 5000,
    });
}

test "SctpTransport.deleteDataChannel: removes the data channel from the list and sid map" {
    var dtls_transport = try DtlsTransport.init(testing.io, testing.allocator, .{
        .on_data = undefined,
        .on_event = undefined,
    });
    defer dtls_transport.deinit();

    var transport = newTestSctpTransport();
    transport.dtls_transport = &dtls_transport;
    defer transport.deinit(testing.allocator);

    const label = "test_channel";
    const params = DataChannel.Parameters{ .ordered = true };

    const data_channel = try transport.newDataChannel(testing.allocator, label, params);
    try testing.expectEqual(1, transport.data_channels.items.len);
    try testing.expectEqual(data_channel, transport.data_channels.items[0]);

    transport.deleteDataChannel(data_channel);
    try testing.expectEqual(0, transport.data_channels.items.len);
}

test "SctpTransport.nextStreamId: dtls client generate even stream ids" {
    var dtls_transport = try DtlsTransport.init(testing.io, testing.allocator, .{
        .on_data = undefined,
        .on_event = undefined,
    });
    defer dtls_transport.deinit();
    try dtls_transport.session.setRole(false);

    var transport = newTestSctpTransport();
    defer transport.deinit(testing.allocator);
    transport.max_channels = 5;
    transport.dtls_transport = &dtls_transport;

    for (&[_]u16{ 0, 2, 4 }) |expected| {
        const sid = try transport.nextStreamId();
        try testing.expectEqual(expected, sid);
        try transport.sid_to_data_channel.put(sid, undefined);
    }

    const err = transport.nextStreamId();
    try testing.expectEqual(error.NoAvailableStreamId, err);

    _ = transport.sid_to_data_channel.remove(2);
    const sid = try transport.nextStreamId();
    try testing.expectEqual(2, sid);
}

test "SctpTransport.nextStreamId: dtls server generate odd stream ids" {
    var dtls_transport = try DtlsTransport.init(testing.io, testing.allocator, .{
        .on_data = undefined,
        .on_event = undefined,
    });
    defer dtls_transport.deinit();
    try dtls_transport.session.setRole(true);

    var transport = newTestSctpTransport();
    defer transport.deinit(testing.allocator);
    transport.max_channels = 7;
    transport.dtls_transport = &dtls_transport;

    for (&[_]u16{ 1, 3, 5 }) |expected| {
        const sid = try transport.nextStreamId();
        try testing.expectEqual(expected, sid);
        try transport.sid_to_data_channel.put(sid, undefined);
    }

    const err = transport.nextStreamId();
    try testing.expectEqual(error.NoAvailableStreamId, err);

    _ = transport.sid_to_data_channel.remove(1);
    const sid = try transport.nextStreamId();
    try testing.expectEqual(1, sid);
}

test "SctpTransport.handleAssocChange: COMM_UP transitions to connected" {
    var transport = newTestSctpTransport();

    var assoc_change = testAssocChange(.COMM_UP);
    try transport.handleAssocChange(&assoc_change);

    try testing.expectEqual(.connected, transport.connection_state.load(.seq_cst));
}

test "SctpTransport.handleAssocChange: COMM_LOST/SHUTDOWN_COMP/CANT_STR_ASSOC transition to closed" {
    const states = [_]sctp.Notification.AssocChange.State{ .COMM_LOST, .SHUTDOWN_COMP, .CANT_STR_ASSOC };
    for (states) |state| {
        var transport = newTestSctpTransport();
        transport.connection_state.store(.connected, .seq_cst);

        var assoc_change = testAssocChange(state);
        try transport.handleAssocChange(&assoc_change);

        try testing.expectEqual(.closed, transport.connection_state.load(.seq_cst));
    }
}

test "SctpTransport.handleAssocChange: RESTART leaves connection state unchanged" {
    var transport = newTestSctpTransport();
    transport.connection_state.store(.connected, .seq_cst);

    var assoc_change = testAssocChange(.RESTART);
    try transport.handleAssocChange(&assoc_change);

    try testing.expectEqual(.connected, transport.connection_state.load(.seq_cst));
}

test "SctpTransport.newDataChannel: creates a new data channel and adds it to the list" {
    const allocator = testing.allocator;

    var transport = newTestSctpTransport();
    defer transport.deinit(allocator);

    const label = "test_channel";
    const params = DataChannel.Parameters{ .ordered = true };

    const data_channel = try transport.newDataChannel(allocator, label, params);

    try testing.expectEqualStrings(label, data_channel.label);
    try testing.expectEqual(true, data_channel.ordered);
    try testing.expectEqual(1, transport.data_channels.items.len);
    try testing.expectEqual(data_channel, transport.data_channels.items[0]);
}

test "SctpTransport.newDataChannel: failed allocatation" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn newDataChannel(alloc: std.mem.Allocator) !void {
            var transport = init(testing.io, alloc, .{ .local_port = 5000, .remote_port = 5000 });
            defer transport.deinit(alloc);
            const label = "test_channel";
            _ = try transport.newDataChannel(alloc, label, .{ .ordered = true });
        }
    }.newDataChannel, .{});
}
