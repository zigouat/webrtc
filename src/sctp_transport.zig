const std = @import("std");
const sctp = @import("sctp");

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
            sctp.deregisterAddress(sctp_transport);
            sctp_transport.socket.close();
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

pub fn resetStreams(sctp_transport: *SctpTranport, stream_ids: []const u16, flags: sctp.StreamResetRequestFlags) !void {
    try sctp_transport.socket.resetStreams(stream_ids, flags);
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
    data_channel.* = try .init(allocator, label, sctp_transport, params);
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
        .stream_reset => try sctp_transport.handleStreamReset(&notif.stream_reset, data),
        else => {},
    }
}

fn handleStreamReset(sctp_transport: *SctpTranport, notif: *const sctp.Notification.StreamResetEvent, data: []const u8) !void {
    if (notif.flags.denied or notif.flags.failed) {
        Logger.warn("stream reset denied or failed", .{});
        return;
    }

    var r = std.Io.Reader.fixed(data[@sizeOf(sctp.Notification.StreamResetEvent)..]);
    while (r.takeInt(u16, .native)) |sid| {
        const data_channel = sctp_transport.getDataChannelBySid(sid) orelse continue;

        if (notif.flags.incoming_ssn and data_channel.ready_state != .closing) {
            sctp_transport.resetStreams(&.{sid}, .{ .outgoing = true }) catch |err| {
                Logger.warn("Failed to mirror stream reset for sid {}: {}\n", .{ sid, err });
            };
        }

        data_channel.setReadyState(.closed);
        sctp_transport.deleteDataChannel(data_channel);
    } else |_| {}
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

pub fn deleteDataChannel(sctp_transport: *SctpTranport, data_channel: *DataChannel) void {
    sctp_transport.mutex.lockUncancelable(sctp_transport.io);
    defer sctp_transport.mutex.unlock(sctp_transport.io);
    sctp_transport.deleteChannelLocked(data_channel);
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

var comm_up_connected_fired: bool = false;
fn commUpTestOnEvent(_: *SctpTranport, event: Event) void {
    if (event == .connection_state and event.connection_state == .connected) {
        comm_up_connected_fired = true;
    }
}

test "SctpTransport.handleAssocChange: COMM_UP deletes channels that fail to get a stream id and still fires connected" {
    var dtls_transport = try DtlsTransport.init(testing.io, testing.allocator, .{
        .on_data = undefined,
        .on_event = undefined,
    });
    defer dtls_transport.deinit();

    var transport = newTestSctpTransport();
    transport.dtls_transport = &dtls_transport;
    transport.on_event = commUpTestOnEvent;
    defer transport.deinit(testing.allocator);
    comm_up_connected_fired = false;

    _ = try transport.newDataChannel(testing.allocator, "chan1", .{});
    _ = try transport.newDataChannel(testing.allocator, "chan2", .{});
    try testing.expectEqual(2, transport.data_channels.items.len);

    var assoc_change = testAssocChange(.COMM_UP);
    assoc_change.outbound_streams = 0;
    assoc_change.inbound_streams = 0;
    try transport.handleAssocChange(&assoc_change);

    try testing.expectEqual(0, transport.data_channels.items.len);
    try testing.expect(comm_up_connected_fired);
    transport.connection_state.store(.new, .seq_cst);
}

test "SctpTransport.handleStreamReset: OUTGOING_SSN finalizes the channel" {
    var dtls_transport = try DtlsTransport.init(testing.io, testing.allocator, .{
        .on_data = undefined,
        .on_event = undefined,
    });
    defer dtls_transport.deinit();

    var transport = newTestSctpTransport();
    transport.dtls_transport = &dtls_transport;
    defer transport.deinit(testing.allocator);

    const data_channel = try transport.newDataChannel(testing.allocator, "chan", .{ .id = 7 });
    try transport.putDataChannel(data_channel.id.?, data_channel);
    data_channel.setReadyState(.closing);

    var closed = false;
    const Ctx = struct {
        fn onEvent(userdata: ?*anyopaque, _: *DataChannel, event: DataChannel.Event) void {
            const flag: *bool = @ptrCast(@alignCast(userdata.?));
            if (event == .close) flag.* = true;
        }
    };
    data_channel.registerCallback(&closed, Ctx.onEvent);

    const stream_reset = sctp.Notification.StreamResetEvent{
        .type = .stream_reset,
        .assoc_id = 0,
        .length = @sizeOf(sctp.Notification.StreamResetEvent) + @sizeOf(u16),
        .flags = .{ .outgoing_ssn = true },
    };
    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try w.writeStruct(stream_reset, .native);
    try w.writeInt(u16, data_channel.id.?, .native);

    try transport.handleStreamReset(&stream_reset, w.buffered());

    try testing.expect(closed);
    try testing.expectEqual(0, transport.data_channels.items.len);
    try testing.expectEqual(null, transport.sid_to_data_channel.get(7));
}

test "SctpTransport.handleStreamReset: DENIED/FAILED leaves the channel untouched" {
    var dtls_transport = try DtlsTransport.init(testing.io, testing.allocator, .{
        .on_data = undefined,
        .on_event = undefined,
    });
    defer dtls_transport.deinit();

    var transport = newTestSctpTransport();
    transport.dtls_transport = &dtls_transport;
    defer transport.deinit(testing.allocator);

    const data_channel = try transport.newDataChannel(testing.allocator, "chan", .{ .id = 7 });
    try transport.putDataChannel(data_channel.id.?, data_channel);

    const stream_reset = sctp.Notification.StreamResetEvent{
        .type = .stream_reset,
        .assoc_id = 0,
        .length = @sizeOf(sctp.Notification.StreamResetEvent) + @sizeOf(u16),
        .flags = .{ .denied = true },
    };
    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try w.writeStruct(stream_reset, .native);
    try w.writeInt(u16, data_channel.id.?, .native);

    try transport.handleStreamReset(&stream_reset, w.buffered());

    try testing.expectEqual(1, transport.data_channels.items.len);
    try testing.expectEqual(.connecting, data_channel.ready_state);
}

test "DataChannel.close: without a stream id finalizes locally" {
    var dtls_transport = try DtlsTransport.init(testing.io, testing.allocator, .{
        .on_data = undefined,
        .on_event = undefined,
    });
    defer dtls_transport.deinit();

    var transport = newTestSctpTransport();
    transport.dtls_transport = &dtls_transport;
    defer transport.deinit(testing.allocator);

    const data_channel = try transport.newDataChannel(testing.allocator, "chan", .{ .ordered = true });
    try testing.expectEqual(null, data_channel.id);

    var closed = false;
    const Ctx = struct {
        fn onEvent(userdata: ?*anyopaque, _: *DataChannel, event: DataChannel.Event) void {
            const flag: *bool = @ptrCast(@alignCast(userdata.?));
            if (event == .close) flag.* = true;
        }
    };
    data_channel.registerCallback(&closed, Ctx.onEvent);

    try data_channel.close();

    try testing.expect(closed);
    try testing.expectEqual(0, transport.data_channels.items.len);
}
