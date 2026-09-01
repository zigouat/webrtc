const std = @import("std");
const sctp = @import("sctp");
const SctpTransport = @import("sctp_transport.zig");

pub fn init() void {
    sctp.init(sendSctpData);
}

pub fn deinit() void {
    sctp.deinit();
}

fn sendSctpData(addr: ?*anyopaque, buffer: ?*anyopaque, len: usize, _: u8, _: u8) callconv(.c) c_int {
    const sctp_transport: *SctpTransport = @ptrCast(@alignCast(addr.?));

    if (buffer) |b| {
        const buf: [*]const u8 = @ptrCast(@alignCast(b));
        const data = buf[0..len];
        sctp_transport.sendData(data) catch |err| {
            std.log.err("Failed to send SCTP data: {}", .{err});
            return sctp.Error.IO;
        };
    }

    return 0;
}
