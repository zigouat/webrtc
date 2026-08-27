const std = @import("std");
const SctpTransport = @import("sctp_transport.zig");

const c = @import("sctp");

pub fn init() void {
    c.usrsctp_init(0, sendSctpData, null);
}

pub fn deinit() void {
    _ = c.usrsctp_finish();
}

fn sendSctpData(addr: ?*anyopaque, buffer: ?*anyopaque, len: usize, _: u8, _: u8) callconv(.c) c_int {
    const sctp_transport: *SctpTransport = @ptrCast(@alignCast(addr.?));

    if (buffer) |b| {
        const buf: [*]const u8 = @ptrCast(@alignCast(b));
        const data = buf[0..len];
        sctp_transport.sendData(data) catch |err| {
            std.log.err("Failed to send SCTP data: {}", .{err});
            return c.EIO;
        };
    }

    return 0;
}
