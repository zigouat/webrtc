const std = @import("std");
const webrtc = @import("webrtc.zig");
const rtp = @import("rtp");
const rtcp = @import("rtcp");
const SendBuffer = @import("utils/send_buffer.zig");

const Io = std.Io;
const RtpSender = @This();
const DtlsTransport = @import("dtls_transport.zig");
const MediaStreamTrack = webrtc.MediaStreamTrack;
const MediaPacket = @import("media").Packet;
const RtpTransceiver = @import("rtp_transceiver.zig");
const Mid = @import("mid.zig");

const rtp_default_header_size = 12;
const max_rtp_payload_size = 1200;

pub const SendError = DtlsTransport.SendError || Io.Reader.Error || error{ NoAssociatedTrack, InvalidDirection };

const RtpHeaderExtensions = struct {
    mid: u16 = 0,
};

const Packetizer = union(enum) {
    vp8: rtp.packetizer.VP8,
    h264: rtp.packetizer.H264,
    opus: rtp.packetizer.Opus,
    none: void,

    fn init(io: Io, ssrc: u32, codec: webrtc.RtpCodecParameters) @This() {
        var rtp_config = rtp.packetizer.RtpConfig.init(io);
        rtp_config.payload_type = @intCast(codec.payload_type);
        rtp_config.ssrc = ssrc;

        if (std.mem.eql(u8, codec.mime_type, webrtc.MimeType.VP8)) {
            return .{ .vp8 = .init(rtp_config) };
        } else if (std.mem.eql(u8, codec.mime_type, webrtc.MimeType.H264)) {
            return .{ .h264 = .init(rtp_config) };
        } else if (std.mem.eql(u8, codec.mime_type, webrtc.MimeType.Opus)) {
            return .{ .opus = .init(rtp_config) };
        }

        return .none;
    }
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
header_extensions: RtpHeaderExtensions,
ssrc: u32,
rtx_ssrc: u32,
report: Report,
packetizer: Packetizer,
rtx_config: ?RtxConfig,
send_buffer: ?SendBuffer,

pub fn init(track: ?MediaStreamTrack) RtpSender {
    return .{
        .track = track,
        .codecs = &.{},
        .header_extensions = .{},
        .ssrc = 0,
        .rtx_ssrc = 0,
        .report = .empty,
        .packetizer = .none,
        .rtx_config = null,
        .send_buffer = null,
    };
}

pub fn deinit(sender: *RtpSender, allocator: std.mem.Allocator) void {
    if (sender.send_buffer) |*send_buffer| {
        send_buffer.deinit(allocator);
        sender.send_buffer = null;
    }
}

pub fn replaceTrack(sender: *RtpSender, new_track: MediaStreamTrack) !void {
    sender.track = new_track;
}

pub fn setStream(sender: *RtpSender, stream: webrtc.MediaStream) void {
    if (sender.track) |*track| track.stream_id = stream.id;
}

pub fn setCodecs(sender: *RtpSender, io: std.Io, allocator: std.mem.Allocator, codecs: []const webrtc.RtpCodecParameters) !void {
    if (sender.codecs.len != 0) {
        // TODO: Handle this use case better. What if the codec is changed?
        // For now do not allow changing codecs after they have been set
        return;
    }

    sender.codecs = codecs;
    sender.packetizer = .none;

    if (codecs.len > 0) {
        const chosen_codec = codecs[0];
        sender.packetizer = .init(io, sender.ssrc, chosen_codec);
        const rtx_codec = webrtc.RtpCodecParameters.findRtx(codecs, chosen_codec.payload_type);

        if (rtx_codec != null and chosen_codec.rtcp_feedbacks.nack) {
            sender.send_buffer = try .init(allocator, 1024, max_rtp_payload_size);
            sender.rtx_config = .{
                .payload_type = rtx_codec.?.payload_type,
                .sequence_number = 0,
            };
        }
    }
}

pub fn setHeaderExtensions(sender: *RtpSender, extensions: []const webrtc.RtpHeaderExtensionParameter) void {
    for (extensions) |ext| {
        if (std.mem.eql(u8, ext.uri, webrtc.mid_extension_uri)) {
            sender.header_extensions.mid = ext.id;
        }
    }
}

/// Sends a media sample to the remote peer.
pub fn sendSample(sender: *RtpSender, sample: *const MediaPacket) SendError!void {
    const tr = try checkAndGetTransceiver(sender);
    const timestamp = Io.Timestamp.now(tr.transport.getIo(), .real).toMicroseconds();

    var buffer = try tr.transport.ice_agent.createPacket();
    defer tr.transport.ice_agent.destroyPacket(buffer);

    const header_size = rtp_default_header_size + try sender.writeHeaderExtensions(tr.mid.?, buffer[rtp_default_header_size..]);
    buffer = buffer[0 .. header_size + max_rtp_payload_size];

    //TODO: refactor this mess
    switch (sender.packetizer) {
        .vp8 => |*p| {
            var it = p.packetize(sample);
            while (it.next(buffer[header_size..])) |*packet|
                try sendAndRecord(tr, packet, header_size, buffer, timestamp);
        },
        .h264 => |*p| {
            var it = p.packetize(sample);
            while (try it.next(buffer[header_size..])) |*packet|
                try sendAndRecord(tr, packet, header_size, buffer, timestamp);
        },
        .opus => |*p| {
            var it = p.packetize(sample);
            while (it.next(buffer[header_size..])) |*packet|
                try sendAndRecord(tr, packet, header_size, buffer, timestamp);
        },
        else => return,
    }
}

/// Sends an RTP packet.
///
/// The sender will update the ssrc and payload type according to the transceiver's configuration.
pub fn sendRtp(sender: *RtpSender, packet: *const rtp.Packet) SendError!void {
    const tr = try checkAndGetTransceiver(sender);

    var buffer = try tr.transport.ice_agent.createPacket();
    defer tr.transport.ice_agent.destroyPacket(buffer);

    const timestamp = Io.Timestamp.now(tr.transport.getIo(), .real).toMicroseconds();
    const header_size = rtp_default_header_size + try sender.writeHeaderExtensions(tr.mid.?, buffer[rtp_default_header_size..]);

    const header: rtp.Packet.Header = .{
        .extension = header_size != rtp_default_header_size,
        .marker = packet.header.marker,
        .padding = false,
        .payload_type = @intCast(tr.sender.codecs[0].payload_type),
        .sequence_number = packet.header.sequence_number,
        .ssrc = sender.ssrc,
        .timestamp = packet.header.timestamp,
    };

    @memcpy(buffer[header_size .. packet.payload.len + header_size], packet.payload);
    try writeHeaderAndSend(tr, header, header_size, packet.payload.len, buffer);
    sender.recordSent(packet, timestamp);
}

pub fn writeReport(sender: *const RtpSender, timestamp: i64, buffer: []u8) []const u8 {
    if (sender.report.packet_count == 0) return &.{};
    std.debug.assert(buffer.len >= rtcp.header_size + rtcp.sr_base_size);
    const length = rtcp.header_size + rtcp.sr_base_size;

    const header: rtcp.Header = .{
        .payload_type = .sender_report,
        .rc = 0,
        .length = length / 4 - 1,
        .padding = false,
    };
    std.mem.writeInt(@Int(.unsigned, @bitSizeOf(rtcp.Header)), buffer[0..rtcp.header_size], @bitCast(header), .big);

    const report = sender.report;
    const codec = sender.codecs[0]; // First codec is used for sending
    const ts = if (timestamp <= report.timestamp) report.timestamp else timestamp;
    const diff: u32 = @intCast(@divTrunc((ts - report.timestamp) * codec.clock_rate, std.time.us_per_s));

    const sender_report: rtcp.SenderReport = .{
        .ssrc = sender.ssrc,
        .ntp_timestamp = microsecondsToNtp(timestamp),
        .rtp_timestamp = report.rtp_timestamp + diff,
        .octet_count = report.octet_count,
        .packet_count = report.packet_count,
    };
    sender_report.encode(buffer[rtcp.header_size..][0..rtcp.sr_base_size]);

    return buffer[0..length];
}

pub fn handleNack(sender: *RtpSender, nack: rtcp.Nack) !void {
    const send_buffer = if (sender.send_buffer) |*sb| sb else return;
    const rtx_config = if (sender.rtx_config) |*rc| rc else return;
    const tr = try checkAndGetTransceiver(sender);

    var it = nack.iterateSequenceNumbers();
    while (it.next()) |seq| {
        const packet = send_buffer.get(seq) orelse continue;

        std.debug.print("Send rtx packet: {}\n", .{seq});

        var buffer = try tr.transport.ice_agent.createPacket();
        defer tr.transport.ice_agent.destroyPacket(buffer);

        const header_size = rtp_default_header_size + try sender.writeHeaderExtensions(tr.mid.?, buffer[rtp_default_header_size..]);

        const header: rtp.Packet.Header = .{
            .extension = header_size != rtp_default_header_size,
            .marker = packet.header.marker,
            .padding = false,
            .payload_type = @intCast(rtx_config.payload_type),
            .sequence_number = rtx_config.sequence_number,
            .ssrc = sender.rtx_ssrc,
            .timestamp = packet.header.timestamp,
        };

        // RFC 4588: RTX payload is the original sequence number followed by the original payload.
        std.mem.writeInt(u16, buffer[header_size..][0..2], seq, .big);
        @memcpy(buffer[header_size + 2 ..][0..packet.payload.len], packet.payload);

        try writeHeaderAndSend(tr, header, header_size, 2 + packet.payload.len, buffer);
        rtx_config.sequence_number +%= 1;
    }
}

fn recordSent(sender: *RtpSender, packet: *const rtp.Packet, timestamp: i64) void {
    sender.report.recordPacket(packet, timestamp);
    if (sender.send_buffer) |*send_buffer| send_buffer.add(packet);
}

fn checkAndGetTransceiver(sender: *RtpSender) !*RtpTransceiver {
    if (sender.track == null) {
        @branchHint(.cold);
        return error.NoAssociatedTrack;
    }

    const tr: *RtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
    if (!tr.canSend()) {
        @branchHint(.unlikely);
        return error.InvalidDirection;
    }

    return tr;
}

fn writeHeaderExtensions(sender: *RtpSender, mid: Mid.Int, buffer: []u8) !usize {
    if (sender.header_extensions.mid == 0) return 0;

    var w = Io.Writer.fixed(buffer);
    var rtp_writer = try rtp.Packet.Extension.Writer.init(.one_byte, &w);
    try rtp_writer.writeItem(.{ .id = @intCast(sender.header_extensions.mid), .value = std.mem.sliceTo(&Mid.toBytes(mid), 0) });
    try rtp_writer.flush();
    return w.buffered().len;
}

fn writeHeaderAndSend(tr: *RtpTransceiver, header: rtp.Packet.Header, header_size: usize, payload_len: usize, buffer: []u8) SendError!void {
    std.mem.writeInt(u96, buffer[0..rtp_default_header_size], @bitCast(header), .big);
    try tr.transport.sendRtp(buffer[0 .. header_size + payload_len]);
}

fn sendAndRecord(tr: *RtpTransceiver, rtp_packet: *const rtp.Packet, header_size: usize, buffer: []u8, timestamp: i64) !void {
    var header = rtp_packet.header;
    header.extension = header_size != rtp_default_header_size;

    try writeHeaderAndSend(tr, header, header_size, rtp_packet.payload.len, buffer);
    tr.sender.recordSent(rtp_packet, timestamp);
}

fn microsecondsToNtp(timestamp: i64) u64 {
    const ntp_seconds = @divTrunc(timestamp, std.time.us_per_s) + webrtc.ntp_unix_epoch_diff;
    const ntp_fraction = @rem(timestamp, std.time.us_per_s);
    return @bitCast((ntp_seconds << 32) | ntp_fraction);
}

const testing = std.testing;

test "setHeaderExtensions: picks the mid extension id, ignores others" {
    var sender: RtpSender = .init(null);
    sender.setHeaderExtensions(&.{
        .{ .id = 9, .uri = "some-other-uri" },
        .{ .id = 3, .uri = webrtc.mid_extension_uri },
    });

    try testing.expectEqual(3, sender.header_extensions.mid);
}

test "setHeaderExtensions: no mid extension leaves it unset" {
    var sender: RtpSender = .init(null);
    sender.setHeaderExtensions(&.{.{ .id = 9, .uri = "some-other-uri" }});

    try testing.expectEqual(0, sender.header_extensions.mid);
}

test "writeHeaderExtensions: not negotiated writes nothing" {
    var sender: RtpSender = .init(null);
    var buffer: [64]u8 = undefined;

    try testing.expectEqual(0, try sender.writeHeaderExtensions(try Mid.fromInt(1), &buffer));
}

test "writeHeaderExtensions: writes a one-byte mid extension" {
    var sender: RtpSender = .init(null);
    sender.header_extensions.mid = 3;

    var buffer: [64]u8 = undefined;
    const len = try sender.writeHeaderExtensions(try Mid.fromInt(12), &buffer);

    const expected = [_]u8{ 0xBE, 0xDE, 0x00, 0x01, 0x31, '1', '2', 0x00 };
    try testing.expectEqualSlices(u8, &expected, buffer[0..len]);
}

test "record packets" {
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

test "convert microseconds to ntp" {
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
