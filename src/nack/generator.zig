const std = @import("std");
const rtp = @import("rtp");
const rtcp = @import("rtcp");
const DtlsTransport = @import("../dtls_transport.zig");

const NackGenerator = @This();
const Io = std.Io;
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
group: Io.Group,
mutex: Io.Mutex,

pub fn init(allocator: std.mem.Allocator, config: Config) NackGenerator {
    Logger.debug("Init nack generator", .{});

    return .{
        .receive_logs = .init(allocator),
        .size = config.size,
        .interval = config.interval,
        .group = .init,
        .mutex = .init,
    };
}

pub fn deinit(self: *NackGenerator, io: Io) void {
    Logger.debug("Deinit nack generator", .{});

    const allocator = self.receive_logs.allocator;
    self.group.cancel(io);

    var it = self.receive_logs.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    self.receive_logs.deinit();
}

pub fn start(self: *NackGenerator, dtls_transport: *DtlsTransport) !void {
    Logger.debug("Start sending nack reports", .{});
    try self.group.concurrent(dtls_transport.getIo(), buildAndSendNack, .{ self, dtls_transport });
}

pub fn handleRtpPacket(self: *NackGenerator, io: Io, packet: *const rtp.Packet) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const entry = try self.receive_logs.getOrPut(packet.header.ssrc);
    errdefer if (!entry.found_existing) self.receive_logs.removeByPtr(entry.key_ptr);

    if (!entry.found_existing) {
        entry.value_ptr.* = try ReceiveLog.init(self.receive_logs.allocator, self.size);
    }

    entry.value_ptr.add(packet.header.sequence_number);
}

pub fn deleteSource(self: *NackGenerator, io: Io, ssrc: u32) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.receive_logs.getPtr(ssrc)) |receive_log| receive_log.deinit(self.receive_logs.allocator);
    _ = self.receive_logs.remove(ssrc);
}

fn buildAndSendNack(self: *NackGenerator, dtls_transport: *DtlsTransport) !void {
    var buffer: [1200]u8 = @splat(0);
    const io = dtls_transport.getIo();

    const duration = Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(self.interval) };
    var timestamp = Io.Clock.Timestamp.now(io, .awake);

    while (true) {
        timestamp = timestamp.addDuration(duration);
        try timestamp.wait(io);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var it = NackGeneratorIterator.init(self);
        var slice: []u8 = buffer[0..];
        while (true) {
            const msg = it.next(slice) catch {
                if (slice.len == buffer.len) {
                    Logger.err("Failed to generate rtcp nack: Buffer too small", .{});
                    break;
                }

                dtls_transport.sendRtcp(buffer[0 .. buffer.len - slice.len]) catch |err| {
                    Logger.err("Failed to send rtcp nack: {}", .{err});
                };
                slice = buffer[0..];
                continue;
            };

            if (msg) |m| {
                slice = slice[m.len..];
                continue;
            }

            if (slice.len != buffer.len) {
                dtls_transport.sendRtcp(buffer[0 .. buffer.len - slice.len]) catch |err| {
                    Logger.err("Failed to send rtcp nack: {}", .{err});
                };
            }
            break;
        }
    }
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

    fn next(self: *NackGeneratorIterator, buffer: []u8) Io.Writer.Error!?[]const u8 {
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

test "NackGenerator.handleRtpPacket: failed init" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 127 });
    defer gen.deinit(testing.io);
}

test "NackGenerator.handleRtpPacket: creates one receive log per ssrc" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit(testing.io);

    try gen.handleRtpPacket(testing.io, &testPacket(1, 1));
    try testing.expectEqual(1, gen.receive_logs.count());

    try gen.handleRtpPacket(testing.io, &testPacket(1, 2));
    try testing.expectEqual(1, gen.receive_logs.count());

    try gen.handleRtpPacket(testing.io, &testPacket(2, 1));
    try testing.expectEqual(2, gen.receive_logs.count());
}

test "NackGenerator.generateRtcpNacks: no packet is emitted when nothing is missing" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit(testing.io);

    try gen.handleRtpPacket(testing.io, &testPacket(1, 1));
    try gen.handleRtpPacket(testing.io, &testPacket(1, 2));

    var buffer: [64]u8 = undefined;
    var it = NackGeneratorIterator.init(&gen);
    try testing.expectEqual(null, try it.next(&buffer));
}

test "NackGenerator.generateRtcpNacks: emits a NACK listing the missing sequence numbers" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit(testing.io);

    try gen.handleRtpPacket(testing.io, &testPacket(42, 1));
    try gen.handleRtpPacket(testing.io, &testPacket(42, 2));
    try gen.handleRtpPacket(testing.io, &testPacket(42, 5));

    var buffer: [64]u8 = undefined;
    var it = NackGeneratorIterator.init(&gen);
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

test "NackGenerator.generateRtcpNacks: only ssrcs with missing packets produce a NACK" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit(testing.io);

    try gen.handleRtpPacket(testing.io, &testPacket(1, 1));
    try gen.handleRtpPacket(testing.io, &testPacket(1, 2));

    try gen.handleRtpPacket(testing.io, &testPacket(2, 10));
    try gen.handleRtpPacket(testing.io, &testPacket(2, 12));

    var buffer: [64]u8 = undefined;
    var it = NackGeneratorIterator.init(&gen);
    const data = (try it.next(&buffer)) orelse return error.TestExpectedNack;
    const packet = try rtcp.Packet.decode(data);
    try testing.expectEqual(2, packet.payload.nack.media_ssrc);

    try testing.expectEqual(null, try it.next(&buffer));
}

test "NackGenerator.generateRtcpNacks: build rtcp compound packet" {
    var gen = NackGenerator.init(testing.allocator, .{ .size = 128 });
    defer gen.deinit(testing.io);

    try gen.handleRtpPacket(testing.io, &testPacket(1, 1));
    try gen.handleRtpPacket(testing.io, &testPacket(1, 4));

    try gen.handleRtpPacket(testing.io, &testPacket(2, 10));
    try gen.handleRtpPacket(testing.io, &testPacket(2, 12));

    var buffer: [128]u8 = undefined;
    var written: usize = 0;
    var it = NackGeneratorIterator.init(&gen);
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

test "NackGenerator.deleteSource" {
    var gen = NackGenerator.init(testing.allocator, .{});
    defer gen.deinit(testing.io);

    try gen.handleRtpPacket(testing.io, &testPacket(1, 1));
    try gen.handleRtpPacket(testing.io, &testPacket(2, 10));

    gen.deleteSource(testing.io, 1);
    try testing.expectEqual(1, gen.receive_logs.count());
}
