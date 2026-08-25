const std = @import("std");
const c = @import("sctp");

const DtlsTransport = @import("dtls_transport.zig");
const SctpTranport = @This();
const Socket = c.struct_socket;

const Logger = std.log.scoped(.sctp_transport);

const InitMsg = extern struct {
    num_ostreams: u16 = 0,
    max_instreams: u16 = 0,
    max_attempts: u16 = 0,
    max_init_timeo: u16 = 0,
};

const Family = enum(u16) {
    AF_CONN = 123,
};

const ConnAddress = extern struct {
    family: Family,
    port: u16,
    addr: ?*anyopaque,
};

pub const InitConfig = struct {
    local_port: u16,
    remote_port: u16,
    dtls_transport: *DtlsTransport,
};

socket: *Socket,
dtls_transport: *DtlsTransport,
local_port: u16,
remote_port: u16,

pub fn init(sctp_transport: *SctpTranport, init_config: InitConfig) !void {
    sctp_transport.socket = c.usrsctp_socket(
        c.AF_CONN,
        c.SOCK_STREAM,
        c.IPPROTO_SCTP,
        receive_cb,
        null,
        0,
        sctp_transport,
    ) orelse return error.SocketCreationFailed;

    try sctp_transport.setDefaultOptions();
    try sctp_transport.subscribeToEvents();

    sctp_transport.dtls_transport = init_config.dtls_transport;
    sctp_transport.local_port = init_config.local_port;
    sctp_transport.remote_port = init_config.remote_port;
}

pub fn connect(sctp_transport: *SctpTranport) !void {
    c.usrsctp_register_address(sctp_transport);

    var sock_addr = ConnAddress{
        .family = .AF_CONN,
        .port = std.mem.nativeToBig(u16, sctp_transport.local_port),
        .addr = sctp_transport,
    };

    if (c.usrsctp_bind(sctp_transport.socket, @ptrCast(@alignCast(&sock_addr)), @sizeOf(ConnAddress)) != 0) {
        return error.BindFailed;
    }

    var remote_addr = ConnAddress{
        .family = .AF_CONN,
        .port = std.mem.nativeToBig(u16, sctp_transport.remote_port),
        .addr = sctp_transport,
    };

    const result = c.usrsctp_connect(sctp_transport.socket, @ptrCast(&remote_addr), @sizeOf(ConnAddress));
    if (result < 0 and c.__errno_location().* != c.EINPROGRESS) {
        return error.ConnectFailed;
    }
}

pub fn deinit(sctp_transport: *SctpTranport) void {
    c.usrsctp_close(sctp_transport.socket);
}

pub fn sendData(sctp_transport: *SctpTranport, data: []const u8) !void {
    try sctp_transport.dtls_transport.sendData(data);
}

pub fn handleIncomingData(sctp_transport: *SctpTranport, data: []const u8) void {
    Logger.debug("received sctp data of length: {}", .{data.len});
    c.usrsctp_conninput(sctp_transport, data.ptr, data.len, 0);
}

fn setDefaultOptions(sctp_transport: *const SctpTranport) !void {
    _ = c.usrsctp_set_non_blocking(sctp_transport.socket, 1);

    var one: c_int = 1;
    try sctp_transport.setSocketOption(c.SCTP_NODELAY, &one, @sizeOf(c_int));

    var streams = InitMsg{ .max_instreams = 65535, .num_ostreams = 65535 };
    try sctp_transport.setSocketOption(c.SCTP_INITMSG, &streams, @sizeOf(InitMsg));

    var reset: c.sctp_assoc_value = .{
        .assoc_id = c.SCTP_FUTURE_ASSOC,
        .assoc_value = c.SCTP_ENABLE_RESET_STREAM_REQ,
    };
    try sctp_transport.setSocketOption(c.SCTP_ENABLE_STREAM_RESET, &reset, @sizeOf(c.sctp_assoc_value));
}

fn setSocketOption(sctp_transport: *const SctpTranport, option_name: c_int, option_value: *anyopaque, size: u32) !void {
    if (c.usrsctp_setsockopt(
        sctp_transport.socket,
        c.IPPROTO_SCTP,
        option_name,
        option_value,
        size,
    ) != 0) {
        return error.SetSocketOptionFailed;
    }
}

fn subscribeToEvents(sctp_transport: *const SctpTranport) !void {
    const event_types = [_]u16{
        c.SCTP_ASSOC_CHANGE,
        c.SCTP_STREAM_RESET_EVENT,
        c.SCTP_SEND_FAILED_EVENT,
        c.SCTP_SHUTDOWN_EVENT,
    };

    for (&event_types) |event_type| {
        var ev: c.sctp_event = .{
            .se_assoc_id = c.SCTP_ALL_ASSOC,
            .se_type = event_type,
            .se_on = 1,
        };

        try sctp_transport.setSocketOption(c.SCTP_EVENT, &ev, @sizeOf(c.sctp_event));
    }
}

fn receive_cb(
    sock: ?*Socket,
    addr: c.union_sctp_sockstore,
    maybe_data: ?*anyopaque,
    len: usize,
    rcvinfo: c.struct_sctp_rcvinfo,
    flags: c_int,
    ulp_info: ?*anyopaque,
) callconv(.c) c_int {
    _ = sock;
    _ = addr;
    _ = rcvinfo;
    _ = ulp_info;

    const data = @as([*]u8, @ptrCast(@alignCast(maybe_data orelse return 1)))[0..len];

    if (flags & c.MSG_NOTIFICATION != 0) {
        std.debug.print("Notification: {x}\n", .{data});
        return 1;
    }

    std.debug.print("Slice: {x}\n", .{data});
    return 1;
}
