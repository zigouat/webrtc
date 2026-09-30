const std = @import("std");
const rtp = @import("rtp");
const rtcp = @import("rtcp");

const NackGenerator = @This();
const ReceiveLog = @import("receive_log.zig");
const HashMap = std.AutoHashMap(u32, ReceiveLog);

const Logger = std.log.scoped(.nack_generator);

/// Nack generation config
pub const Config = struct {
    /// How many packets to keep in the receive log for each SSRC.
    size: u16 = 512,
    /// How often to send NACK reports, in milliseconds.
    interval: u16 = 100,
};

size: u16,
interval: u16,
receive_logs: HashMap,
deadline: i64,
it: ?NackGeneratorIterator,

pub fn init(allocator: std.mem.Allocator, config: Config) NackGenerator {
    Logger.debug("Init nack generator", .{});

    return .{
        .receive_logs = .init(allocator),
        .size = config.size,
        .interval = config.interval,
        .deadline = std.math.maxInt(i64),
        .it = null,
    };
}

pub fn deinit(self: *NackGenerator) void {
    Logger.debug("Deinit nack generator", .{});

    const allocator = self.receive_logs.allocator;

    var it = self.receive_logs.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    self.receive_logs.deinit();
}

pub fn handleRead(self: *NackGenerator, packet: *const rtp.Packet) !void {
    const entry = try self.receive_logs.getOrPut(packet.header.ssrc);
    errdefer if (!entry.found_existing) self.receive_logs.removeByPtr(entry.key_ptr);

    if (!entry.found_existing) {
        entry.value_ptr.* = try ReceiveLog.init(self.receive_logs.allocator, self.size);
    }

    entry.value_ptr.add(packet.header.sequence_number);
}

pub fn handleTimeout(self: *NackGenerator, now: i64) void {
    if (self.deadline == std.math.maxInt(i64)) {
        @branchHint(.cold);
        self.deadline = now + self.interval;
        return;
    }

    if (now >= self.deadline) {
        self.deadline = now + self.interval;
        self.it = NackGeneratorIterator.init(self);
    }
}

pub fn pollTimeout(self: *NackGenerator) i64 {
    return self.deadline;
}

pub fn pollTransmit(self: *NackGenerator, buffer: []u8) !?[]const u8 {
    if (self.it == null) return null;

    var slice: []u8 = buffer;
    while (true) {
        const msg = self.it.?.next(slice) catch {
            if (slice.len == buffer.len) return error.WriteFailed;
            return buffer[0 .. buffer.len - slice.len];
        };

        if (msg) |m| {
            slice = slice[m.len..];
            continue;
        }

        if (slice.len != buffer.len) return buffer[0 .. buffer.len - slice.len];
        self.it = null;
        return null;
    }
}

pub fn deleteSource(self: *NackGenerator, ssrc: u32) void {
    if (self.receive_logs.getPtr(ssrc)) |receive_log| receive_log.deinit(self.receive_logs.allocator);
    _ = self.receive_logs.remove(ssrc);
}

const NackGeneratorIterator = struct {
    it: HashMap.Iterator,
    entry: ?HashMap.Entry,

    fn init(self: *NackGenerator) NackGeneratorIterator {
        var result = NackGeneratorIterator{
            .it = self.receive_logs.iterator(),
            .entry = null,
        };
        result.entry = result.it.next();
        return result;
    }

    fn next(self: *NackGeneratorIterator, buffer: []u8) error{WriteFailed}!?[]const u8 {
        if (self.entry == null) return null;

        var rtcp_header = rtcp.Header{
            .payload_type = .rtp_fb,
            .rc = 1, // NACK
            .length = 0,
            .padding = false,
        };

        while (true) {
            const entry = self.entry.?;
            if (entry.value_ptr.last_consecutive == entry.value_ptr.end) {
                self.entry = self.it.next();
                if (self.entry == null) return null;
                continue;
            }

            var w = try rtcp.Nack.Writer.init(buffer[4..], 0, entry.key_ptr.*);
            var missing_it = entry.value_ptr.iterateMissing();
            while (missing_it.next()) |seq| try w.writeSequenceNumber(seq);

            const nack = try w.finalize();
            rtcp_header.length = @intCast(nack.len / 4);
            std.mem.writeInt(u32, buffer[0..4], @bitCast(rtcp_header), .big);
            self.entry = self.it.next();
            return buffer[0 .. 4 + nack.len];
        }
    }
};

const testing = std.testing;

fn testPacket(ssrc: u32, seq: u16) rtp.Packet {
    return .{
        .header = .{
            .ssrc = ssrc,
            .timestamp = 0,
            .sequence_number = seq,
            .payload_type = 96,
            .marker = false,
            .extension = false,
            .padding = false,
        },
        .payload = &.{},
    };
}

fn triggerNack(gen: *NackGenerator) void {
    gen.handleTimeout(0);
    gen.handleTimeout(gen.interval);
}

test "NackGenerator.handleRtpPacket: failed init" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 127 });
    defer gen.deinit();
}

test "NackGenerator.deleteSource" {
    var gen = NackGenerator.init(testing.allocator, .{});
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(2, 10));

    gen.deleteSource(1);
    try testing.expectEqual(1, gen.receive_logs.count());
}

test "NackGenerator.handleTimeout: first call arms the deadline" {
    var gen = NackGenerator.init(testing.allocator, .{ .interval = 100 });
    defer gen.deinit();

    try testing.expectEqual(std.math.maxInt(i64), gen.pollTimeout());

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 3));

    gen.handleTimeout(1000);
    try testing.expectEqual(1100, gen.pollTimeout());

    var buffer: [128]u8 = undefined;
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.handleTimeout: no nack before the deadline" {
    var gen = NackGenerator.init(testing.allocator, .{ .interval = 100 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 3));

    gen.handleTimeout(1000);
    gen.handleTimeout(1099);
    try testing.expectEqual(1100, gen.pollTimeout());

    var buffer: [128]u8 = undefined;
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.pollTransmit: emits nack after deadline then returns null" {
    var gen = NackGenerator.init(testing.allocator, .{ .interval = 100 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(42, 1));
    try gen.handleRead(&testPacket(42, 2));
    try gen.handleRead(&testPacket(42, 5));

    gen.handleTimeout(1000);
    gen.handleTimeout(1150);
    try testing.expectEqual(1250, gen.pollTimeout());

    var buffer: [128]u8 = undefined;
    const data = (try gen.pollTransmit(&buffer)) orelse return error.TestExpectedNack;

    const packet = try rtcp.Packet.decode(data);
    try testing.expectEqual(42, packet.payload.nack.media_ssrc);

    var seq_it = packet.payload.nack.iterateSequenceNumbers();
    try testing.expectEqual(3, seq_it.next());
    try testing.expectEqual(4, seq_it.next());
    try testing.expectEqual(null, seq_it.next());

    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
    try testing.expectEqual(null, gen.it);
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.pollTransmit: nothing missing returns null" {
    var gen = NackGenerator.init(testing.allocator, .{ .interval = 100 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 2));

    gen.handleTimeout(1000);
    gen.handleTimeout(1100);

    var buffer: [128]u8 = undefined;
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
    try testing.expectEqual(null, gen.it);
}

test "NackGenerator.pollTransmit: buffer too small keeps the iteration" {
    var gen = NackGenerator.init(testing.allocator, .{ .interval = 100 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(42, 1));
    try gen.handleRead(&testPacket(42, 3));

    gen.handleTimeout(1000);
    gen.handleTimeout(1100);

    var small: [8]u8 = undefined;
    try testing.expectError(error.WriteFailed, gen.pollTransmit(&small));

    var buffer: [128]u8 = undefined;
    const data = (try gen.pollTransmit(&buffer)) orelse return error.TestExpectedNack;
    const packet = try rtcp.Packet.decode(data);
    try testing.expectEqual(42, packet.payload.nack.media_ssrc);

    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.pollTransmit: resumes when buffer fills up" {
    var gen = NackGenerator.init(testing.allocator, .{ .interval = 100 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 3));
    try gen.handleRead(&testPacket(2, 10));
    try gen.handleRead(&testPacket(2, 12));

    gen.handleTimeout(1000);
    gen.handleTimeout(1100);

    var buffer: [24]u8 = undefined;
    var ssrcs: [2]u32 = undefined;
    for (&ssrcs) |*ssrc| {
        const data = (try gen.pollTransmit(&buffer)) orelse return error.TestExpectedNack;
        var compound = rtcp.CompoundPacketIterator.init(data);
        const packet = (try compound.next()) orelse return error.TestExpectedRtcpPacket;
        ssrc.* = packet.payload.nack.media_ssrc;
        try testing.expectEqual(null, try compound.next());
    }

    try testing.expect(ssrcs[0] != ssrcs[1]);
    for (ssrcs) |ssrc| try testing.expect(ssrc == 1 or ssrc == 2);
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.pollTransmit: new round after next deadline" {
    var gen = NackGenerator.init(testing.allocator, .{ .interval = 100 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 3));

    gen.handleTimeout(1000);
    gen.handleTimeout(1100);

    var buffer: [128]u8 = undefined;
    try testing.expect((try gen.pollTransmit(&buffer)) != null);
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));

    gen.handleTimeout(1150);
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));

    gen.handleTimeout(1200);
    try testing.expect((try gen.pollTransmit(&buffer)) != null);
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.handleRead: creates one receive log per ssrc" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try testing.expectEqual(1, gen.receive_logs.count());

    try gen.handleRead(&testPacket(1, 2));
    try testing.expectEqual(1, gen.receive_logs.count());

    try gen.handleRead(&testPacket(2, 1));
    try testing.expectEqual(2, gen.receive_logs.count());
}

test "NackGenerator.handleRead: invalid log size does not keep the entry" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 127 });
    defer gen.deinit();

    try testing.expectError(error.InvalidSize, gen.handleRead(&testPacket(1, 1)));
    try testing.expectEqual(0, gen.receive_logs.count());
}

test "NackGenerator.pollTransmit: only ssrcs with missing packets produce a nack" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 2));
    try gen.handleRead(&testPacket(2, 10));
    try gen.handleRead(&testPacket(2, 12));

    triggerNack(&gen);

    var buffer: [128]u8 = undefined;
    const data = (try gen.pollTransmit(&buffer)) orelse return error.TestExpectedNack;

    var compound = rtcp.CompoundPacketIterator.init(data);
    const packet = (try compound.next()) orelse return error.TestExpectedRtcpPacket;
    try testing.expectEqual(2, packet.payload.nack.media_ssrc);

    var seq_it = packet.payload.nack.iterateSequenceNumbers();
    try testing.expectEqual(11, seq_it.next());
    try testing.expectEqual(null, seq_it.next());

    try testing.expectEqual(null, try compound.next());
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.pollTransmit: builds rtcp compound packet" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 4));
    try gen.handleRead(&testPacket(2, 10));
    try gen.handleRead(&testPacket(2, 12));

    triggerNack(&gen);

    var buffer: [128]u8 = undefined;
    const data = (try gen.pollTransmit(&buffer)) orelse return error.TestExpectedNack;

    var compound = rtcp.CompoundPacketIterator.init(data);
    var seen: [2]bool = @splat(false);
    for (0..2) |_| {
        const packet = (try compound.next()) orelse return error.TestExpectedRtcpPacket;
        try testing.expectEqual(.rtp_fb, packet.header.payload_type);
        try testing.expectEqual(.nack, std.meta.activeTag(packet.payload));

        const ssrc = packet.payload.nack.media_ssrc;
        try testing.expect(ssrc == 1 or ssrc == 2);
        seen[ssrc - 1] = true;
    }

    try testing.expect(seen[0] and seen[1]);
    try testing.expectEqual(null, try compound.next());
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.pollTransmit: handles sequence number wraparound" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 65534));
    try gen.handleRead(&testPacket(1, 1));

    triggerNack(&gen);

    var buffer: [128]u8 = undefined;
    const data = (try gen.pollTransmit(&buffer)) orelse return error.TestExpectedNack;
    const packet = try rtcp.Packet.decode(data);

    var seq_it = packet.payload.nack.iterateSequenceNumbers();
    try testing.expectEqual(65535, seq_it.next());
    try testing.expectEqual(0, seq_it.next());
    try testing.expectEqual(null, seq_it.next());
}

test "NackGenerator.pollTransmit: missing packet received before deadline is not nacked" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 3));
    try gen.handleRead(&testPacket(1, 2));

    triggerNack(&gen);

    var buffer: [128]u8 = undefined;
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}

test "NackGenerator.pollTransmit: deleted source is not nacked" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit();

    try gen.handleRead(&testPacket(1, 1));
    try gen.handleRead(&testPacket(1, 3));
    gen.deleteSource(1);

    triggerNack(&gen);

    var buffer: [128]u8 = undefined;
    try testing.expectEqual(null, try gen.pollTransmit(&buffer));
}
