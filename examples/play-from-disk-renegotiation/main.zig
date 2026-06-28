const std = @import("std");
const Io = std.Io;

const index = @embedFile("index.html");

pub fn main(init: std.process.Init) !void {
    _ = init;

    std.debug.print("{s}\n", .{index});
}
