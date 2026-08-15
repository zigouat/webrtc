const std = @import("std");

const ReceiveLog = @This();

packets: []u64,
size: u16,
last_consecutive: u16,
end: u16,
started: bool,

pub const MissingSequenceNumberIterator = struct {
    start: u16,
    end: u16,
    log: *const ReceiveLog,

    pub fn init(log: *const ReceiveLog) @This() {
        return .{
            .start = log.last_consecutive +% 1,
            .end = log.end,
            .log = log,
        };
    }

    pub fn next(self: *MissingSequenceNumberIterator) ?u16 {
        while (self.start != self.end) : (self.start +%= 1) {
            if (!self.log.isReceived(self.start)) {
                const result = self.start;
                self.start +%= 1;
                return result;
            }
        }
        return null;
    }
};

pub fn init(allocator: std.mem.Allocator, size: u16) error{ InvalidSize, OutOfMemory }!ReceiveLog {
    if (size < 64 or !std.math.isPowerOfTwo(size)) {
        return error.InvalidSize;
    }

    const packets = try allocator.alloc(u64, size / 64);
    @memset(packets, 0);

    return .{
        .packets = packets,
        .size = size,
        .last_consecutive = 0,
        .end = 0,
        .started = false,
    };
}

pub fn deinit(self: *ReceiveLog, allocator: std.mem.Allocator) void {
    allocator.free(self.packets);
}

pub fn add(self: *ReceiveLog, seq: u16) void {
    if (!self.started) {
        self.started = true;
        self.last_consecutive = seq;
        self.end = seq;
        self.setReceived(seq);
        return;
    }

    const diff = @as(i16, @bitCast(seq)) - @as(i16, @bitCast(self.end));
    if (diff == 0) return;
    if (diff > 0) {
        @branchHint(.likely);
        var i = self.end +% 1;
        while (i != seq) : (i +%= 1) {
            self.clearReceived(i);
        }
        self.end = seq;

        if (self.last_consecutive +% 1 == seq) {
            self.last_consecutive = seq;
        } else if (seq -% self.last_consecutive > self.size) {
            self.last_consecutive = seq -% self.size;
            self.fixLastConsecutive();
        }
    } else {
        if (self.last_consecutive +% 1 == seq) {
            self.last_consecutive = seq;
            self.fixLastConsecutive();
        }
    }

    self.setReceived(seq);
}

pub fn iterateMissing(self: *const ReceiveLog) MissingSequenceNumberIterator {
    return .init(self);
}

fn setReceived(self: *ReceiveLog, seq: u16) void {
    const pos = seq % self.size;
    self.packets[pos / 64] |= (@as(u64, 1) << @intCast(pos % 64));
}

fn clearReceived(self: *ReceiveLog, seq: u16) void {
    const pos = seq % self.size;
    self.packets[pos / 64] &= ~(@as(u64, 1) << @intCast(pos % 64));
}

fn isReceived(self: *const ReceiveLog, seq: u16) bool {
    const pos = seq % self.size;
    return self.packets[pos / 64] & (@as(u64, 1) << @intCast(pos % 64)) != 0;
}

fn fixLastConsecutive(self: *ReceiveLog) void {
    var i = self.last_consecutive +% 1;
    while (i != self.end) : (i +%= 1) {
        if (!self.isReceived(i)) break;
        self.last_consecutive = i;
    }
}

const testing = std.testing;

test "init" {
    var log = try ReceiveLog.init(testing.allocator, 64);
    defer log.deinit(testing.allocator);

    try testing.expectEqual(false, log.started);
    try testing.expectEqual(0, log.end);
    for (log.packets) |word| try testing.expectEqual(0, word);
}

test "init: invalid size" {
    for (&[_]u16{ 0, 32, 63, 120 }) |size| {
        try testing.expectError(error.InvalidSize, ReceiveLog.init(testing.allocator, size));
    }
}

test "add" {
    var log = try ReceiveLog.init(testing.allocator, 128);
    defer log.deinit(testing.allocator);

    log.add(10);
    try testing.expect(log.started);
    try testing.expectEqual(10, log.end);
    try testing.expectEqual(true, log.isReceived(10));

    log.add(10);
    try testing.expectEqual(10, log.end);
    try testing.expect(log.isReceived(10));

    log.add(11);
    try testing.expectEqual(11, log.end);
    try testing.expect(log.isReceived(11));

    log.add(15);
    try testing.expectEqual(15, log.end);
    try testing.expect(log.isReceived(15));
    for (12..15) |seq| try testing.expect(!log.isReceived(@intCast(seq)));

    log.add(12);
    try testing.expectEqual(15, log.end);
    try testing.expect(log.isReceived(12));

    log.add(65535);
    try testing.expectEqual(15, log.end);
    try testing.expect(log.isReceived(65535));

    log.add(0);
    try testing.expectEqual(15, log.end);
    try testing.expect(log.isReceived(0));
}

test "add: advancing past a stale bucket clears its previously received bit" {
    var log = try ReceiveLog.init(testing.allocator, 128);
    defer log.deinit(testing.allocator);

    log.add(5);
    log.add(6);
    try testing.expect(log.isReceived(5));
    try testing.expect(log.isReceived(6));

    log.add(134);
    try testing.expectEqual(134, log.end);
    try testing.expect(!log.isReceived(5));
    try testing.expect(log.isReceived(134));
}

test "iterateMissing" {
    var log = try ReceiveLog.init(testing.allocator, 128);
    defer log.deinit(testing.allocator);

    log.add(65533);
    log.add(1);
    log.add(65534);
    log.add(3);
    log.add(4);
    log.add(8);

    var iter = log.iterateMissing();
    try testing.expectEqual(65535, iter.next() orelse unreachable);
    try testing.expectEqual(0, iter.next() orelse unreachable);
    try testing.expectEqual(2, iter.next() orelse unreachable);
    try testing.expectEqual(5, iter.next() orelse unreachable);
    try testing.expectEqual(6, iter.next() orelse unreachable);
    try testing.expectEqual(7, iter.next() orelse unreachable);
    try testing.expectEqual(null, iter.next());
}
