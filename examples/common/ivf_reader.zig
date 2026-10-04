const std = @import("std");
const ivf = @import("ivf");
const media = @import("media");

const IvfReader = @This();
const Io = std.Io;

file: Io.File,
reader: Io.File.Reader,
ivf_r: ivf.Reader,
read_buffer: [1024]u8,
curr_packet: ?media.Packet,
start_timestamp: i64,

pub fn init(ivf_reader: *IvfReader, io: Io, path: []const u8) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    errdefer file.close(io);

    ivf_reader.file = file;
    ivf_reader.reader = file.reader(io, &ivf_reader.read_buffer);
    ivf_reader.ivf_r = ivf.Reader.init(&ivf_reader.reader.interface) catch |err| switch (err) {
        error.ReadFailed => return ivf_reader.reader.err.?,
        else => |e| return e,
    };
    ivf_reader.curr_packet = null;
    ivf_reader.start_timestamp = std.math.maxInt(i64);
}

pub fn deinit(self: *IvfReader, allocator: std.mem.Allocator) void {
    self.file.close(self.reader.io);
    if (self.curr_packet) |*p| p.deinit(allocator);
}

pub fn next(self: *IvfReader, allocator: std.mem.Allocator, now: i64) !?media.Packet {
    const video_stream = &self.ivf_r.stream;
    if (self.start_timestamp == std.math.maxInt(i64)) self.start_timestamp = now;

    if (self.curr_packet == null) {
        self.curr_packet = self.ivf_r.next(allocator) catch |err| switch (err) {
            error.ReadFailed => return self.reader.err.?,
            else => |e| return e,
        };
    }

    const dest_time_base = media.Rational.ofDen(90_000);
    const elapsed: u64 = @bitCast(now - self.start_timestamp);

    while (true) {
        if (self.curr_packet == null) return error.EndOfStream;
        const dts = elapsed * video_stream.time_base.den / std.time.ms_per_s;
        if (self.curr_packet.?.dts >= dts) return null;

        var p = self.curr_packet.?;
        p.scaleTimestamps(video_stream.time_base, dest_time_base);

        self.curr_packet = self.ivf_r.next(allocator) catch |err| switch (err) {
            error.ReadFailed => return self.reader.err.?,
            else => |e| return e,
        };

        return p;
    }
}
