const std = @import("std");
const constants = @import("../constants.zig");
const webrtc = @import("../webrtc.zig");
const rtp = @import("rtp");
const rtcp = @import("rtcp");
const SendBuffer = @import("../nack/send_buffer.zig");

const Io = std.Io;
const InternalRtpSender = @This();
const MediaStreamTrack = webrtc.MediaStreamTrack;
const MediaPacket = @import("media").Packet;
const InternalRtpTransceiver = @import("internal_rtp_transceiver.zig");
const Mid = @import("../mid.zig");

pub const AllocError = std.mem.Allocator.Error;
/// The sender has no negotiated track or the transceiver cannot send.
pub const StateError = error{ NoAssociatedTrack, InvalidDirection };
pub const WriteError = StateError || Io.Writer.Error || error{PayloadTooLarge};
pub const PacketizeError = rtp.Packetizer.Error;

const RtpHeaderExtensions = struct {
    mid: u16 = 0,
};

const RtxConfig = struct {
    sequence_number: u16,
    payload_type: u8,
};

const Report = struct {
    last_sequence_number: ?u16,
    rtp_timestamp: u32,
    timestamp: i64,
    packet_count: u32,
    octet_count: u32,

    const empty: Report = .{
        .last_sequence_number = null,
        .rtp_timestamp = 0,
        .timestamp = 0,
        .packet_count = 0,
        .octet_count = 0,
    };

    fn recordPacket(report: *Report, packet: *const rtp.Packet, timestamp: i64) void {
        const last_seq_number = report.last_sequence_number orelse packet.header.sequence_number -% 1;
        const diff = @as(i16, @bitCast(packet.header.sequence_number)) -% @as(i16, @bitCast(last_seq_number));

        // check for out of order packets
        if (diff > 0) {
            report.last_sequence_number = packet.header.sequence_number;
            report.rtp_timestamp = packet.header.timestamp;
            report.timestamp = timestamp;
        }

        report.packet_count += 1;
        report.octet_count += @intCast(packet.payload.len);
    }
};

track: ?MediaStreamTrack,
codecs: []const webrtc.RtpCodecParameters,
/// The codec currently used for sending.
///
/// Currently it's the first codec in the list of negotiated codecs.
codec: ?webrtc.RtpCodecParameters,
header_extensions: RtpHeaderExtensions,
ssrc: u32,
rtx_ssrc: u32,
report: Report,
packetizer: rtp.Packetizer,
rtx_config: ?RtxConfig,
send_buffer: ?SendBuffer,
/// Store the nacks after processing NACK rtcp packet.
nacks: std.Deque(u16),

pub fn init(track: ?MediaStreamTrack) InternalRtpSender {
    return .{
        .track = track,
        .codecs = &.{},
        .codec = null,
        .header_extensions = .{},
        .ssrc = 0,
        .rtx_ssrc = 0,
        .report = .empty,
        .packetizer = undefined,
        .rtx_config = null,
        .send_buffer = null,
        .nacks = .empty,
    };
}

pub fn deinit(sender: *InternalRtpSender, allocator: std.mem.Allocator) void {
    sender.nacks.deinit(allocator);
    if (sender.send_buffer) |*send_buffer| {
        send_buffer.deinit(allocator);
        sender.send_buffer = null;
    }
}

/// Resets the sender to its initial state, preparing it for reuse.
pub fn reset(sender: *InternalRtpSender, allocator: std.mem.Allocator) void {
    sender.codecs = &.{};
    sender.codec = null;
    while (sender.nacks.popFront()) |_| {}
    sender.header_extensions = .{};
    sender.report = .empty;
    sender.packetizer = undefined;
    sender.rtx_config = null;
    sender.ssrc = 0;
    sender.rtx_ssrc = 0;
    if (sender.send_buffer) |*send_buffer| {
        send_buffer.deinit(allocator);
        sender.send_buffer = null;
    }
}

pub fn replaceTrack(sender: *InternalRtpSender, new_track: MediaStreamTrack) void {
    sender.track = new_track;
}

pub fn setStream(sender: *InternalRtpSender, stream: webrtc.MediaStream) void {
    if (sender.track) |*track| track.stream_id = stream.id;
}

pub fn setCodecs(
    sender: *InternalRtpSender,
    allocator: std.mem.Allocator,
    r: std.Random,
    codecs: []const webrtc.RtpCodecParameters,
    send_buffer_size: u16,
) AllocError!void {
    const curr_codecs = sender.codecs;
    sender.codecs = codecs;

    // Stop sending if no codecs are negotiated
    if (codecs.len == 0) {
        if (sender.send_buffer) |*send_buffer| {
            send_buffer.deinit(allocator);
            sender.send_buffer = null;
        }
        sender.codec = null;
        return;
    }

    // For now keep the old negotiated codec.
    // In the future we'll add callback to notify the application that the negotiated codec has changed
    // and let it decide what to do.
    if (curr_codecs.len != 0) return;
    const tr: *InternalRtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));

    const chosen_codec = sender.codecs[0];
    const rtx_codec = webrtc.RtpCodecParameters.findRtx(codecs, chosen_codec.payload_type);

    if (tr.canSend() and chosen_codec.rtp_codec.rtcp_feedbacks.nack) {
        if (sender.send_buffer == null) {
            sender.send_buffer = try SendBuffer.init(
                allocator,
                send_buffer_size,
                constants.max_packet_size,
            );
        }
    } else if (sender.send_buffer) |*send_buffer| {
        send_buffer.deinit(allocator);
        sender.send_buffer = null;
    }

    sender.rtx_config = if (rtx_codec) |rc| .{
        .sequence_number = 0,
        .payload_type = @intCast(rc.payload_type),
    } else null;

    const mime = chosen_codec.rtp_codec.mime_type;
    const codec: rtp.Packetizer.Codec = if (std.mem.eql(u8, mime, webrtc.MimeType.VP8))
        .vp8
    else if (std.mem.eql(u8, mime, webrtc.MimeType.H264))
        .h264
    else if (std.mem.eql(u8, mime, webrtc.MimeType.Opus))
        .opus
    else
        unreachable;

    sender.packetizer = rtp.Packetizer.init(codec, .{
        .payload_type = @intCast(chosen_codec.payload_type),
        .seq_number = r.uintAtMost(u16, std.math.maxInt(u16)),
        .ssrc = sender.ssrc,
        .fragment_size = constants.max_rtp_payload_size,
    });
    sender.codec = chosen_codec;
}

pub fn setHeaderExtensions(sender: *InternalRtpSender, extensions: []const webrtc.RtpHeaderExtensionParameter) void {
    for (extensions) |ext| {
        if (std.mem.eql(u8, ext.uri, webrtc.mid_extension_uri)) {
            sender.header_extensions.mid = ext.id;
        }
    }
}

pub const SamplePacketizerIterator = struct {
    rtp_sender: *InternalRtpSender,
    packet_it: rtp.Packetizer.Iterator,
    mid: Mid.Int,

    pub fn init(sender: *InternalRtpSender, media_packet: *const MediaPacket) StateError!SamplePacketizerIterator {
        const tr = try sender.checkAndGetTransceiver();
        return .{
            .rtp_sender = sender,
            .packet_it = sender.packetizer.packetize(media_packet),
            .mid = tr.mid.?,
        };
    }

    pub fn next(it: *SamplePacketizerIterator, buffer: []u8, now_us: i64) PacketizeError!?[]const u8 {
        if (buffer.len < constants.rtp_default_header_size) return error.WriteFailed;
        const header_size = constants.rtp_default_header_size + try it.rtp_sender.writeHeaderExtensions(
            it.mid,
            buffer[constants.rtp_default_header_size..],
        );

        var rtp_packet = try it.packet_it.next(buffer[header_size..]) orelse return null;
        rtp_packet.header.extension = header_size != constants.rtp_default_header_size;
        std.mem.writeInt(u96, buffer[0..constants.rtp_default_header_size], @bitCast(rtp_packet.header), .big);

        it.rtp_sender.report.recordPacket(&rtp_packet, now_us);
        if (it.rtp_sender.send_buffer) |*send_buffer| send_buffer.add(&rtp_packet);
        return buffer[0 .. header_size + rtp_packet.payload.len];
    }
};

pub fn handleMediaPacketWrite(sender: *InternalRtpSender, sample: *const MediaPacket) StateError!SamplePacketizerIterator {
    return try SamplePacketizerIterator.init(sender, sample);
}

pub fn handleWrite(sender: *InternalRtpSender, packet: *const rtp.Packet, buffer: []u8, now_us: i64) WriteError![]const u8 {
    if (packet.payload.len > constants.max_rtp_payload_size) return error.PayloadTooLarge;
    if (buffer.len < constants.rtp_default_header_size + packet.payload.len) return error.WriteFailed;
    const tr = try checkAndGetTransceiver(sender);

    const header_size = constants.rtp_default_header_size + try sender.writeHeaderExtensions(
        tr.mid.?,
        buffer[constants.rtp_default_header_size..],
    );

    const packet_size = header_size + packet.payload.len;
    if (packet_size > buffer.len) return error.WriteFailed;

    const header: rtp.Packet.Header = .{
        .extension = header_size != constants.rtp_default_header_size,
        .marker = packet.header.marker,
        .padding = false,
        .payload_type = @intCast(sender.codec.?.payload_type),
        .sequence_number = packet.header.sequence_number,
        .ssrc = sender.ssrc,
        .timestamp = packet.header.timestamp,
    };

    std.mem.writeInt(u96, buffer[0..constants.rtp_default_header_size], @bitCast(header), .big);
    @memcpy(buffer[header_size..packet_size], packet.payload);

    const new_packet: rtp.Packet = .{
        .header = header,
        .payload = packet.payload,
    };

    sender.report.recordPacket(&new_packet, now_us);
    if (sender.send_buffer) |*send_buffer| send_buffer.add(&new_packet);
    return buffer[0..packet_size];
}

pub fn writeRtcpSenderReport(sender: *InternalRtpSender, timestamp: i64, buffer: []u8) error{WriteFailed}![]const u8 {
    const codec = sender.codec orelse return &.{};
    const report = &sender.report;
    if (report.packet_count == 0) return &.{};

    const length = rtcp.header_size + rtcp.sr_base_size;
    if (buffer.len < length) return error.WriteFailed;

    const header: rtcp.Header = .{
        .payload_type = .sender_report,
        .rc = 0,
        .length = length / 4 - 1,
        .padding = false,
    };

    std.mem.writeInt(@Int(.unsigned, @bitSizeOf(rtcp.Header)), buffer[0..rtcp.header_size], @bitCast(header), .big);

    const ts = if (timestamp <= report.timestamp) report.timestamp else timestamp;
    const diff: u32 = @intCast(@divTrunc(@as(i128, (ts - report.timestamp)) * codec.rtp_codec.clock_rate, std.time.us_per_s));

    const sender_report: rtcp.SenderReport = .{
        .ssrc = sender.ssrc,
        .ntp_timestamp = microsecondsToNtp(timestamp),
        .rtp_timestamp = report.rtp_timestamp +% diff,
        .octet_count = report.octet_count,
        .packet_count = report.packet_count,
    };
    sender_report.encode(buffer[rtcp.header_size..][0..rtcp.sr_base_size]);
    return buffer[0..length];
}

pub fn handleRtcpNack(sender: *InternalRtpSender, allocator: std.mem.Allocator, nack: rtcp.Nack) error{OutOfMemory}!bool {
    if (sender.send_buffer == null) return false;
    _ = checkAndGetTransceiver(sender) catch return false;
    var it = nack.iterateSequenceNumbers();
    while (it.next()) |seq| try sender.nacks.pushBack(allocator, seq);
    return true;
}

pub fn nextNack(sender: *InternalRtpSender, buffer: []u8) (AllocError || Io.Writer.Error)!?[]const u8 {
    const send_buffer = if (sender.send_buffer) |*sb| sb else return null;
    const is_rtx = sender.rtx_config != null;
    const tr = checkAndGetTransceiver(sender) catch return null;

    if (buffer.len < constants.rtp_default_header_size) return error.WriteFailed;

    while (true) {
        const seq = sender.nacks.front() orelse return null;
        const header_size = constants.rtp_default_header_size + try sender.writeHeaderExtensions(
            tr.mid.?,
            buffer[constants.rtp_default_header_size..],
        );
        // RFC 4588: RTX payload is the original sequence number followed by the original payload.
        const payload_offset = header_size + @as(usize, if (is_rtx) 2 else 0);
        if (buffer.len < payload_offset) return error.WriteFailed;
        const packet = try send_buffer.get(seq, buffer[payload_offset..]) orelse {
            _ = sender.nacks.popFront();
            continue;
        };

        const header: rtp.Packet.Header = .{
            .extension = header_size != constants.rtp_default_header_size,
            .marker = packet.header.marker,
            .padding = false,
            .payload_type = @intCast(if (is_rtx) sender.rtx_config.?.payload_type else sender.codec.?.payload_type),
            .sequence_number = if (is_rtx) sender.rtx_config.?.sequence_number else seq,
            .ssrc = if (is_rtx) sender.rtx_ssrc else sender.ssrc,
            .timestamp = packet.header.timestamp,
        };

        if (is_rtx) {
            std.mem.writeInt(u16, buffer[header_size..][0..2], seq, .big);
            sender.rtx_config.?.sequence_number +%= 1;
        }
        const payload_len = if (is_rtx) 2 + packet.payload.len else packet.payload.len;
        std.mem.writeInt(u96, buffer[0..constants.rtp_default_header_size], @bitCast(header), .big);

        _ = sender.nacks.popFront();
        return buffer[0 .. header_size + payload_len];
    }
}

fn checkAndGetTransceiver(sender: *InternalRtpSender) StateError!*InternalRtpTransceiver {
    if (sender.track == null or sender.codec == null) {
        @branchHint(.cold);
        return error.NoAssociatedTrack;
    }

    const tr: *InternalRtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
    if (!tr.canSend()) {
        @branchHint(.unlikely);
        return error.InvalidDirection;
    }

    return tr;
}

fn writeHeaderExtensions(sender: *InternalRtpSender, mid: Mid.Int, buffer: []u8) Io.Writer.Error!usize {
    if (sender.header_extensions.mid == 0) return 0;

    var w = Io.Writer.fixed(buffer);
    var rtp_writer = try rtp.Packet.Extension.Writer.init(.one_byte, &w);
    try rtp_writer.writeItem(.{ .id = @intCast(sender.header_extensions.mid), .value = std.mem.sliceTo(&Mid.toBytes(mid), 0) });
    try rtp_writer.flush();
    return w.buffered().len;
}

fn microsecondsToNtp(timestamp: i64) u64 {
    const ntp_seconds = @divTrunc(timestamp, std.time.us_per_s) + constants.ntp_unix_epoch_diff;
    const ntp_fraction = @rem(timestamp, std.time.us_per_s);
    return @bitCast((ntp_seconds << 32) | ntp_fraction);
}

const testing = std.testing;

var prng = std.Random.DefaultPrng.init(0xdeadbeef);

fn testTransceiver(current_direction: ?InternalRtpTransceiver.Direction) InternalRtpTransceiver {
    return .{
        .sender = InternalRtpSender.init(null),
        .receiver = undefined,
        .kind = .video,
        .direction = .sendrecv,
        .current_direction = current_direction,
    };
}

test "InternalRtpSender.setCodecs: no-op when no codecs are negotiated and none were set" {
    var sender = InternalRtpSender.init(null);
    try sender.setCodecs(testing.allocator, prng.random(), &.{}, 16);

    try testing.expectEqual(0, sender.codecs.len);
    try testing.expect(sender.send_buffer == null);
}

test "InternalRtpSender.setCodecs: sets codecs and initializes the packetizer for the chosen codec" {
    var tr = testTransceiver(null);
    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000 } },
    };

    try tr.sender.setCodecs(testing.allocator, prng.random(), &codecs, 16);

    try testing.expectEqual(1, tr.sender.codecs.len);
    try testing.expectEqual(96, tr.sender.codec.?.payload_type);
    try testing.expectEqual(.vp8, tr.sender.packetizer.codec);
}

test "InternalRtpSender.setCodecs: enables the send buffer when the transceiver can send and rtx+nack are negotiated" {
    var tr = testTransceiver(.sendrecv);
    defer tr.sender.deinit(testing.allocator);

    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000, .rtcp_feedbacks = .{ .nack = true } } },
        .{ .payload_type = 97, .rtp_codec = .{ .mime_type = webrtc.MimeType.Rtx, .clock_rate = 90_000, .fmtp_params = .{ .rtx = .{ .apt = 96 } } } },
    };

    try tr.sender.setCodecs(testing.allocator, prng.random(), &codecs, 16);
    try testing.expect(tr.sender.send_buffer != null);
}

test "InternalRtpSender.setCodecs: leaves the send buffer disabled when the transceiver cannot send" {
    var tr = testTransceiver(.recvonly);
    defer tr.sender.deinit(testing.allocator);

    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000, .rtcp_feedbacks = .{ .nack = true } } },
        .{ .payload_type = 97, .rtp_codec = .{ .mime_type = webrtc.MimeType.Rtx, .clock_rate = 90_000, .fmtp_params = .{ .rtx = .{ .apt = 96 } } } },
    };

    try tr.sender.setCodecs(testing.allocator, prng.random(), &codecs, 16);
    try testing.expect(tr.sender.send_buffer == null);
}

test "InternalRtpSender.setCodecs: enables the send buffer on nack alone, without rtx" {
    const with_nack_no_rtx = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000, .rtcp_feedbacks = .{ .nack = true } } },
    };

    var tr = testTransceiver(.sendrecv);
    defer tr.sender.deinit(testing.allocator);

    try tr.sender.setCodecs(testing.allocator, prng.random(), &with_nack_no_rtx, 16);
    try testing.expect(tr.sender.send_buffer != null);
}

test "InternalRtpSender.setCodecs: leaves the send buffer disabled on rtx alone, without nack" {
    const with_rtx_no_nack = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000 } },
        .{ .payload_type = 97, .rtp_codec = .{ .mime_type = webrtc.MimeType.Rtx, .clock_rate = 90_000, .fmtp_params = .{ .rtx = .{ .apt = 96 } } } },
    };

    var tr = testTransceiver(.sendrecv);
    defer tr.sender.deinit(testing.allocator);

    try tr.sender.setCodecs(testing.allocator, prng.random(), &with_rtx_no_nack, 16);

    try testing.expect(tr.sender.send_buffer == null);
}

test "InternalRtpSender.setCodecs: ignores the codec list on subsequent calls, keeping the first negotiated codecs" {
    var tr = testTransceiver(null);

    const first = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000 } },
    };
    const second = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 111, .rtp_codec = .{ .mime_type = webrtc.MimeType.Opus, .clock_rate = 48_000 } },
    };

    try tr.sender.setCodecs(testing.allocator, prng.random(), &first, 16);
    try tr.sender.setCodecs(testing.allocator, prng.random(), &second, 16);

    try testing.expectEqual(1, tr.sender.codecs.len);
    try testing.expectEqual(96, tr.sender.codec.?.payload_type);
    try testing.expectEqual(.vp8, tr.sender.packetizer.codec);
}

test "InternalRtpSender.setHeaderExtensions: picks the mid extension id, ignores others" {
    var sender = InternalRtpSender.init(null);
    sender.setHeaderExtensions(&.{
        .{ .id = 9, .uri = "some-other-uri" },
        .{ .id = 3, .uri = webrtc.mid_extension_uri },
    });

    try testing.expectEqual(3, sender.header_extensions.mid);
}

test "InternalRtpSender.setHeaderExtensions: no mid extension leaves it unset" {
    var sender = InternalRtpSender.init(null);
    sender.setHeaderExtensions(&.{.{ .id = 9, .uri = "some-other-uri" }});

    try testing.expectEqual(0, sender.header_extensions.mid);
}

test "InternalRtpSender.writeHeaderExtensions: not negotiated writes nothing" {
    var sender = InternalRtpSender.init(null);
    var buffer: [64]u8 = undefined;

    try testing.expectEqual(0, try sender.writeHeaderExtensions(try Mid.fromInt(1), &buffer));
}

test "InternalRtpSender.writeHeaderExtensions: writes a one-byte mid extension" {
    var sender = InternalRtpSender.init(null);
    sender.header_extensions.mid = 3;

    var buffer: [64]u8 = undefined;
    const len = try sender.writeHeaderExtensions(try Mid.fromInt(12), &buffer);

    const expected = [_]u8{ 0xBE, 0xDE, 0x00, 0x01, 0x31, '1', '2', 0x00 };
    try testing.expectEqualSlices(u8, &expected, buffer[0..len]);
}

test "InternalRtpSender: record packets" {
    var report: Report = .empty;
    const payload = "hello";
    var packet: rtp.Packet = .{
        .header = .{
            .ssrc = 0,
            .timestamp = 1000,
            .sequence_number = 10,
            .payload_type = 96,
            .marker = false,
            .extension = false,
            .padding = false,
        },
        .payload = payload,
    };

    report.recordPacket(&packet, 5000);

    try testing.expectEqual(10, report.last_sequence_number);
    try testing.expectEqual(1000, report.rtp_timestamp);
    try testing.expectEqual(5000, report.timestamp);
    try testing.expectEqual(1, report.packet_count);
    try testing.expectEqual(payload.len, report.octet_count);

    packet.header.timestamp = 2000;
    packet.header.sequence_number = 11;

    report.recordPacket(&packet, 6000);
    try testing.expectEqual(11, report.last_sequence_number);
    try testing.expectEqual(2000, report.rtp_timestamp);
    try testing.expectEqual(6000, report.timestamp);
    try testing.expectEqual(2, report.packet_count);
    try testing.expectEqual(payload.len * 2, report.octet_count);

    packet.header.timestamp = 1500;
    packet.header.sequence_number = 9;

    report.recordPacket(&packet, 7000);

    try testing.expectEqual(11, report.last_sequence_number);
    try testing.expectEqual(2000, report.rtp_timestamp);
    try testing.expectEqual(6000, report.timestamp);
    try testing.expectEqual(3, report.packet_count);
    try testing.expectEqual(payload.len * 3, report.octet_count);
}

test "InternalRtpSender.handleWrite: rejects oversized payloads and short buffers without recording" {
    var tr = testTransceiver(.sendrecv);
    defer tr.sender.deinit(testing.allocator);
    tr.mid = 0;
    tr.sender.track = .{ .id = @splat(0), .kind = .video, .stream_id = null, .muted = false };

    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000, .rtcp_feedbacks = .{ .nack = true } } },
    };
    try tr.sender.setCodecs(testing.allocator, prng.random(), &codecs, 16);

    var payload: [constants.max_rtp_payload_size + 1]u8 = @splat(0xAB);
    var packet: rtp.Packet = .{
        .header = .{ .ssrc = 0, .timestamp = 1000, .sequence_number = 10, .payload_type = 96, .marker = false, .extension = false, .padding = false },
        .payload = &payload,
    };

    var buffer: [constants.max_packet_size]u8 = undefined;
    try testing.expectError(error.PayloadTooLarge, tr.sender.handleWrite(&packet, &buffer, 0));

    packet.payload = payload[0..constants.max_rtp_payload_size];
    const packet_size = constants.rtp_default_header_size + packet.payload.len;
    try testing.expectError(error.WriteFailed, tr.sender.handleWrite(&packet, buffer[0 .. constants.rtp_default_header_size - 1], 0));
    try testing.expectError(error.WriteFailed, tr.sender.handleWrite(&packet, buffer[0 .. packet_size - 1], 0));
    try testing.expectEqual(null, tr.sender.report.last_sequence_number);
    try testing.expectEqual(null, try tr.sender.send_buffer.?.get(10, &buffer));

    const written = try tr.sender.handleWrite(&packet, buffer[0..packet_size], 0);
    try testing.expectEqual(packet_size, written.len);
    try testing.expectEqual(10, tr.sender.report.last_sequence_number);
}

test "InternalRtpSender.SamplePacketizerIterator: short buffers fail without recording" {
    var tr = testTransceiver(.sendrecv);
    defer tr.sender.deinit(testing.allocator);
    tr.mid = 0;
    tr.sender.track = .{ .id = @splat(0), .kind = .video, .stream_id = null, .muted = false };

    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000, .rtcp_feedbacks = .{ .nack = true } } },
    };
    try tr.sender.setCodecs(testing.allocator, prng.random(), &codecs, 16);

    const data: [100]u8 = @splat(0xAB);
    const sample: MediaPacket = .{ .data = &data };
    var it = try tr.sender.handleMediaPacketWrite(&sample);

    var buffer: [constants.max_packet_size]u8 = undefined;
    const packet_size = constants.rtp_default_header_size + 1 + data.len;
    try testing.expectError(error.WriteFailed, it.next(buffer[0 .. constants.rtp_default_header_size - 1], 0));
    try testing.expectError(error.WriteFailed, it.next(buffer[0 .. packet_size - 1], 0));
    try testing.expectEqual(null, tr.sender.report.last_sequence_number);

    const packet = (try it.next(buffer[0..packet_size], 0)).?;
    try testing.expectEqual(packet_size, packet.len);
    try testing.expectEqual(null, try it.next(&buffer, 0));
}

test "InternalRtpSender.nextNack: skips unknown packets and keeps the nack on a short buffer" {
    var tr = testTransceiver(.sendrecv);
    defer tr.sender.deinit(testing.allocator);
    tr.mid = 0;
    tr.sender.track = .{ .id = @splat(0), .kind = .video, .stream_id = null, .muted = false };

    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .rtp_codec = .{ .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000, .rtcp_feedbacks = .{ .nack = true } } },
    };
    try tr.sender.setCodecs(testing.allocator, prng.random(), &codecs, 16);

    const payload: [100]u8 = @splat(0xAB);
    const packet: rtp.Packet = .{
        .header = .{ .ssrc = 0, .timestamp = 1000, .sequence_number = 10, .payload_type = 96, .marker = false, .extension = false, .padding = false },
        .payload = &payload,
    };
    var buffer: [constants.max_packet_size]u8 = undefined;
    _ = try tr.sender.handleWrite(&packet, &buffer, 0);

    try tr.sender.nacks.pushBack(testing.allocator, 9);
    try tr.sender.nacks.pushBack(testing.allocator, 10);

    const packet_size = constants.rtp_default_header_size + payload.len;
    try testing.expectError(error.WriteFailed, tr.sender.nextNack(buffer[0 .. packet_size - 1]));
    try testing.expectEqual(1, tr.sender.nacks.len);
    try testing.expectEqual(10, tr.sender.nacks.front().?);

    const retransmit = (try tr.sender.nextNack(buffer[0..packet_size])).?;
    try testing.expectEqual(packet_size, retransmit.len);
    try testing.expectEqualSlices(u8, &payload, retransmit[constants.rtp_default_header_size..]);
    try testing.expectEqual(null, try tr.sender.nextNack(&buffer));
}

test "InternalRtpSender: convert microseconds to ntp" {
    {
        const ntp = microsecondsToNtp(1782228674132465);
        try testing.expectEqual(0xEDE52542, ntp >> 32);
        try testing.expectEqual(132465, ntp & std.math.maxInt(u32));
    }
    {
        const ntp = microsecondsToNtp(1782228863900100);
        try testing.expectEqual(0xEDE525FF, ntp >> 32);
        try testing.expectEqual(900100, ntp & std.math.maxInt(u32));
    }
}
