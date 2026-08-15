const std = @import("std");
const rtp = @import("rtp");
const rtcp = @import("rtcp");

const NackGenerator = @This();
const Io = std.Io;
const ReceiveLog = @import("receive_log.zig");

receive_logs: std.AutoHashMap(u32, ReceiveLog),
size: u16,

pub fn init(allocator: std.mem.Allocator, size: u16) NackGenerator {
    return .{
        .receive_logs = .init(allocator),
        .size = size,
    };
}

pub fn deinit(self: *NackGenerator) void {
    const allocator = self.receive_logs.allocator;

    var it = self.receive_logs.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    self.receive_logs.deinit();
}

pub fn handleRtpPacket(self: *NackGenerator, packet: *const rtp.Packet) !void {
    const entry = try self.receive_logs.getOrPut(packet.header.ssrc);
    if (!entry.found_existing) {
        entry.value_ptr.* = try ReceiveLog.init(self.receive_logs.allocator, self.size);
    }

    entry.value_ptr.add(packet.header.sequence_number);
}

pub fn generateRtcpNacks(self: *NackGenerator) NackGeneratorIterator {
    return NackGeneratorIterator.init(self);
}

pub const NackGeneratorIterator = struct {
    it: std.AutoHashMap(u32, ReceiveLog).Iterator,

    pub fn init(self: *NackGenerator) NackGeneratorIterator {
        return .{ .it = self.receive_logs.iterator() };
    }

    pub fn next(self: *NackGeneratorIterator, buffer: []u8) Io.Writer.Error!?[]const u8 {
        var rtcp_header = rtcp.Header{
            .payload_type = .rtp_fb,
            .rc = 1, // NACK
            .length = 0,
            .padding = false,
        };

        while (self.it.next()) |entry| {
            if (entry.value_ptr.last_consecutive == entry.value_ptr.end) continue;

            var w = try rtcp.Nack.Writer.init(buffer[4..], 0, entry.key_ptr.*);
            var missing_it = entry.value_ptr.iterateMissing();
            while (missing_it.next()) |seq| try w.writeSequenceNumber(seq);

            const nack = try w.finalize();
            rtcp_header.length = @intCast(nack.len / 4);
            std.mem.writeInt(u32, buffer[0..4], @bitCast(rtcp_header), .big);
            return buffer[0 .. 4 + nack.len];
        }
        return null;
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

test "handleRtpPacket: creates one receive log per ssrc" {
    var gen = NackGenerator.init(testing.allocator, 128);
    defer gen.deinit();

    try gen.handleRtpPacket(&testPacket(1, 1));
    try testing.expectEqual(1, gen.receive_logs.count());

    try gen.handleRtpPacket(&testPacket(1, 2));
    try testing.expectEqual(1, gen.receive_logs.count());

    try gen.handleRtpPacket(&testPacket(2, 1));
    try testing.expectEqual(2, gen.receive_logs.count());
}

test "generateRtcpNacks: no packet is emitted when nothing is missing" {
    var gen = NackGenerator.init(testing.allocator, 128);
    defer gen.deinit();

    try gen.handleRtpPacket(&testPacket(1, 1));
    try gen.handleRtpPacket(&testPacket(1, 2));

    var buffer: [64]u8 = undefined;
    var it = gen.generateRtcpNacks();
    try testing.expectEqual(null, try it.next(&buffer));
}

test "generateRtcpNacks: emits a NACK listing the missing sequence numbers" {
    var gen = NackGenerator.init(testing.allocator, 128);
    defer gen.deinit();

    try gen.handleRtpPacket(&testPacket(42, 1));
    try gen.handleRtpPacket(&testPacket(42, 2));
    try gen.handleRtpPacket(&testPacket(42, 5));

    var buffer: [64]u8 = undefined;
    var it = gen.generateRtcpNacks();
    const data = (try it.next(&buffer)) orelse return error.TestExpectedNack;

    const packet = try rtcp.Packet.decode(data);
    try testing.expectEqual(.rtp_fb, packet.header.payload_type);
    try testing.expectEqual(.nack, std.meta.activeTag(packet.payload));
    try testing.expectEqual(42, packet.payload.nack.media_ssrc);

    var seq_it = packet.payload.nack.iterateSequenceNumbers();
    try testing.expectEqual(3, seq_it.next());
    try testing.expectEqual(4, seq_it.next());
    try testing.expectEqual(null, seq_it.next());

    try testing.expectEqual(null, try it.next(&buffer));
}

test "generateRtcpNacks: only ssrcs with missing packets produce a NACK" {
    var gen = NackGenerator.init(testing.allocator, 128);
    defer gen.deinit();

    try gen.handleRtpPacket(&testPacket(1, 1));
    try gen.handleRtpPacket(&testPacket(1, 2));

    try gen.handleRtpPacket(&testPacket(2, 10));
    try gen.handleRtpPacket(&testPacket(2, 12));

    var buffer: [64]u8 = undefined;
    var it = gen.generateRtcpNacks();
    const data = (try it.next(&buffer)) orelse return error.TestExpectedNack;
    const packet = try rtcp.Packet.decode(data);
    try testing.expectEqual(2, packet.payload.nack.media_ssrc);

    try testing.expectEqual(null, try it.next(&buffer));
}

test "generateRtcpNacks: build rtcp compound packet" {
    var gen = NackGenerator.init(testing.allocator, 128);
    defer gen.deinit();

    try gen.handleRtpPacket(&testPacket(1, 1));
    try gen.handleRtpPacket(&testPacket(1, 4));

    try gen.handleRtpPacket(&testPacket(2, 10));
    try gen.handleRtpPacket(&testPacket(2, 12));

    var buffer: [128]u8 = undefined;
    var written: usize = 0;
    var it = gen.generateRtcpNacks();
    var data = (try it.next(&buffer)) orelse return error.TestExpectedNack;
    written += data.len;

    data = (try it.next(buffer[written..])) orelse return error.TestExpectedNack;
    written += data.len;

    try testing.expectEqual(null, try it.next(buffer[written..]));

    var compound_packet = rtcp.CompoundPacketIterator.init(buffer[0..written]);
    const packet1 = (try compound_packet.next()) orelse return error.TestExpectedRtcpPacket;
    try testing.expectEqual(.rtp_fb, packet1.header.payload_type);
    try testing.expectEqual(.nack, std.meta.activeTag(packet1.payload));
    try testing.expectEqual(1, packet1.payload.nack.media_ssrc);

    const packet2 = (try compound_packet.next()) orelse return error.TestExpectedRtcpPacket;
    try testing.expectEqual(.rtp_fb, packet2.header.payload_type);
    try testing.expectEqual(.nack, std.meta.activeTag(packet2.payload));
    try testing.expectEqual(2, packet2.payload.nack.media_ssrc);

    try testing.expectEqual(null, try compound_packet.next());
}
