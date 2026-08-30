const std = @import("std");
const sctp = @import("sctp");

const DataChannel = @import("data_channel.zig");
const DtlsTransport = @import("dtls_transport.zig");
const SctpTranport = @This();

const Logger = std.log.scoped(.sctp_transport);

pub const ConnectionState = enum { new, connecting, connected, closed };

pub const InitConfig = struct {
    local_port: u16,
    remote_port: u16,
};

socket: *sctp.Socket,
connection_state: ConnectionState,
local_port: u16,
remote_port: u16,
dtls_transport: *DtlsTransport,
data_channels: std.ArrayList(*DataChannel),

pub fn init(init_config: InitConfig) SctpTranport {
    return .{
        .connection_state = .new,
        .local_port = init_config.local_port,
        .remote_port = init_config.remote_port,
        .data_channels = .empty,
        .dtls_transport = undefined,
        .socket = undefined,
    };
}

pub fn connect(sctp_transport: *SctpTranport, dtls_transport: *DtlsTransport) !void {
    if (sctp_transport.connection_state != .new) return;

    sctp_transport.dtls_transport = dtls_transport;
    sctp_transport.connection_state = .connecting;

    sctp_transport.socket = try sctp.Socket.create(.{
        .receive_cb = receive_cb,
        .ctx = sctp_transport,
        .non_blocking = true,
        .no_delay = true,
        .enable_stream_reset = true,
    });

    var init_msg = sctp.InitMsg{ .max_instreams = std.math.maxInt(u16), .num_ostreams = std.math.maxInt(u16) };
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
    if (sctp_transport.connection_state == .closed) return;
    sctp_transport.connection_state = .closed;
    sctp_transport.socket.close();
}

pub fn deinit(sctp_transport: *SctpTranport, allocator: std.mem.Allocator) void {
    for (sctp_transport.data_channels.items) |data_channel| {
        allocator.destroy(data_channel);
    }
    sctp_transport.data_channels.deinit(allocator);
    sctp.deregisterAddress(sctp_transport);
    switch (sctp_transport.connection_state) {
        .connecting, .connected => sctp_transport.socket.close(),
        else => {},
    }
}

pub fn sendData(sctp_transport: *SctpTranport, data: []const u8) !void {
    try sctp_transport.dtls_transport.sendData(data);
}

pub fn handleIncomingData(sctp_transport: *SctpTranport, data: []const u8) void {
    switch (sctp_transport.connection_state) {
        .new, .closed => return,
        else => {},
    }

    Logger.debug("received sctp data of length: {}", .{data.len});
    sctp.connInput(sctp_transport, data);
}

pub fn addDataChannel(sctp_transport: *SctpTranport, allocator: std.mem.Allocator, label: []const u8) !*DataChannel {
    const data_channel = try allocator.create(DataChannel);
    errdefer allocator.destroy(data_channel);
    data_channel.* = .{
        .id = @intCast(sctp_transport.data_channels.items.len + 2),
        .label = label,
        .ordered = true,
    };
    try sctp_transport.data_channels.append(allocator, data_channel);

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
        sctp_transport.handleNotification(data);
        return 1;
    }

    const ppid = std.mem.bigToNative(u32, rcvinfo.ppid);
    const stream_id = rcvinfo.sid;

    sctp_transport.handleAppData(ppid, stream_id, data) catch |err| {
        Logger.err("Error handling app data: {}\n", .{err});
    };
    return 1;
}

fn handleNotification(sctp_transport: *SctpTranport, data: []u8) void {
    const notif: *sctp.Notification = @ptrCast(@alignCast(data.ptr));
    Logger.info("handle notification: {s}", .{@tagName(notif.header.type)});

    switch (notif.header.type) {
        .assoc_change => sctp_transport.handleAssocChange(&notif.assoc_change),
        .shutdown => sctp_transport.close(),
        else => {},
    }
}

fn handleAssocChange(sctp_transport: *SctpTranport, assoc_change: *sctp.Notification.AssocChange) void {
    switch (assoc_change.state) {
        .COMM_UP => {
            Logger.debug("sctp association up", .{});
            sctp_transport.connection_state = .connected;
        },
        .COMM_LOST, .SHUTDOWN_COMP, .CANT_STR_ASSOC => {
            Logger.debug("sctp association down", .{});
            sctp_transport.connection_state = .closed;
        },
        .RESTART => Logger.warn("sctp association restarted", .{}),
    }
}

fn handleAppData(sctp_transport: *SctpTranport, ppid: u32, stream_id: u16, data: []u8) !void {
    _ = sctp_transport;
    _ = ppid;
    _ = stream_id;
    _ = data;
}
