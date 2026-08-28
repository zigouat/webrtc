const std = @import("std");
const sctp = @import("sctp");

const DataChannel = @import("data_channel.zig");
const DtlsTransport = @import("dtls_transport.zig");
const SctpTranport = @This();

const Logger = std.log.scoped(.sctp_transport);

pub const ConnectionState = enum { new, connected, failed, closed };

pub const InitConfig = struct {
    local_port: u16,
    remote_port: u16,
    dtls_transport: *DtlsTransport,
};

socket: *sctp.Socket,
connection_state: ConnectionState,
local_port: u16,
remote_port: u16,
dtls_transport: *DtlsTransport,

pub fn init(sctp_transport: *SctpTranport, init_config: InitConfig) !void {
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

    sctp_transport.connection_state = .new;
    sctp_transport.dtls_transport = init_config.dtls_transport;
    sctp_transport.local_port = init_config.local_port;
    sctp_transport.remote_port = init_config.remote_port;
}

pub fn connect(sctp_transport: *SctpTranport) !void {
    const socket = sctp_transport.socket;
    sctp.registerAddress(sctp_transport);
    errdefer sctp.deregisterAddress(sctp_transport);

    var sock_addr = sctp.SockaddrConn.init(std.mem.nativeToBig(u16, sctp_transport.local_port), null);
    try socket.bind(&sock_addr);

    var remote_addr = sctp.SockaddrConn.init(std.mem.nativeToBig(u16, sctp_transport.remote_port), sctp_transport);
    try socket.connect(&remote_addr);
}

pub fn deinit(sctp_transport: *SctpTranport) void {
    sctp.deregisterAddress(sctp_transport);
    sctp_transport.socket.close();
}

pub fn sendData(sctp_transport: *SctpTranport, data: []const u8) !void {
    try sctp_transport.dtls_transport.sendData(data);
}

pub fn handleIncomingData(sctp_transport: *SctpTranport, data: []const u8) void {
    Logger.debug("received sctp data of length: {}", .{data.len});
    sctp.connInput(sctp_transport, data);
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
    const notification: *sctp.Notification = @ptrCast(@alignCast(data.ptr));
    _ = notification;
    _ = sctp_transport;
}

fn handleAppData(sctp_transport: *SctpTranport, ppid: u32, stream_id: u16, data: []u8) !void {
    _ = sctp_transport;
    _ = ppid;
    _ = stream_id;
    _ = data;
}
