const std = @import("std");

/// Packed representation of an SDP media identifier ("a=mid"): up to 3 ASCII
pub const Int = u24;

pub fn fromInt(value: u16) error{MidOverflow}!Int {
    if (value > 999) return error.MidOverflow;
    var bytes: [3]u8 = @splat(0);
    _ = std.fmt.bufPrint(&bytes, "{}", .{value}) catch unreachable;
    return @bitCast(bytes);
}

pub fn fromBytes(bytes: []const u8) error{MidTooLong}!Int {
    if (bytes.len > 3) return error.MidTooLong;
    var buf: [3]u8 = @splat(0);
    @memcpy(buf[0..bytes.len], bytes);
    return @bitCast(buf);
}

pub fn toBytes(value: Int) [3]u8 {
    return @bitCast(value);
}

test {
    const testing = std.testing;
    try testing.expectEqual(try fromBytes("12"), try fromInt(12));
    try testing.expectError(error.MidOverflow, fromInt(1000));
    try testing.expectError(error.MidTooLong, fromBytes("abcd"));
    try testing.expectEqualStrings("7", std.mem.sliceTo(&toBytes(try fromInt(7)), 0));
}
