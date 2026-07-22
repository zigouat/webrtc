const std = @import("std");
const webrtc = @import("webrtc.zig");
const rtp = @import("rtp");
const rtcp = @import("rtcp");

const Io = std.Io;
const RtpSender = @This();
const DtlsTransport = @import("dtls_transport.zig");
const MediaStreamTrack = webrtc.MediaStreamTrack;
const MediaPacket = @import("media").Packet;
const RtpTransceiver = @import("rtp_transceiver.zig");

const rtp_header_size = 12; // No header extension are sent for now.

track: ?MediaStreamTrack,
codecs: []const webrtc.RtpCodecParameters,
ssrc: u32,
report: Report,
packetizer: union(enum) {
    vp8: rtp.packetizer.VP8,
    h264: rtp.packetizer.H264,
    opus: rtp.packetizer.Opus,
    none: void,
},

pub const SendError = DtlsTransport.SendError || Io.Reader.Error || error{ NoAssociatedTrack, InvalidDirection };

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

pub fn init(track: ?MediaStreamTrack) RtpSender {
    return .{
        .track = track,
        .codecs = &.{},
        .ssrc = 0,
        .report = .empty,
        .packetizer = .none,
    };
}

pub fn replaceTrack(sender: *RtpSender, new_track: MediaStreamTrack) !void {
    sender.track = new_track;
}

pub fn setStream(sender: *RtpSender, stream: webrtc.MediaStream) void {
    if (sender.track) |*track| track.stream_id = stream.id;
}

pub fn setCodecs(sender: *RtpSender, io: std.Io, codecs: []const webrtc.RtpCodecParameters) void {
    if (sender.codecs.len != 0) {
        // TODO: Handle this use case better. What if the codec is changed?
        // For now do not allow changing codecs after they have been set
        return;
    }

    sender.codecs = codecs;
    sender.packetizer = .none;

    if (codecs.len > 0) {
        const codec = codecs[0];
        var rtp_config = rtp.packetizer.RtpConfig.init(io);
        rtp_config.payload_type = @intCast(codec.payload_type);
        rtp_config.ssrc = sender.ssrc;

        if (std.mem.eql(u8, codec.mime_type, webrtc.MimeType.VP8)) {
            sender.packetizer = .{ .vp8 = .init(rtp_config) };
        } else if (std.mem.eql(u8, codec.mime_type, webrtc.MimeType.H264)) {
            sender.packetizer = .{ .h264 = .init(rtp_config) };
        } else if (std.mem.eql(u8, codec.mime_type, webrtc.MimeType.Opus)) {
            sender.packetizer = .{ .opus = .init(rtp_config) };
        }
    }
}

/// Sends a media sample to the remote peer.
pub fn sendSample(sender: *RtpSender, sample: *const MediaPacket) SendError!void {
    const tr = try checkAndGetTransceiver(sender);

    var buffer = try tr.transport.ice_agent.createPacket();
    defer tr.transport.ice_agent.destroyPacket(buffer);

    buffer = buffer[0 .. rtp_header_size + 1200];

    const timestamp = Io.Timestamp.now(tr.transport.getIo(), .real).toMicroseconds();

    //TODO: refactor this mess
    switch (sender.packetizer) {
        .vp8 => |*p| {
            var it = p.packetize(sample);
            while (it.next(buffer[rtp_header_size..])) |packet|
                try sendAndRecord(tr, &packet, buffer, timestamp);
        },
        .h264 => |*p| {
            var it = p.packetize(sample);
            while (try it.next(buffer[rtp_header_size..])) |packet|
                try sendAndRecord(tr, &packet, buffer, timestamp);
        },
        .opus => |*p| {
            var it = p.packetize(sample);
            while (it.next(buffer[rtp_header_size..])) |packet|
                try sendAndRecord(tr, &packet, buffer, timestamp);
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

    const header: rtp.Packet.Header = .{
        .extension = false,
        .marker = packet.header.marker,
        .padding = false,
        .payload_type = @intCast(tr.sender.codecs[0].payload_type),
        .sequence_number = packet.header.sequence_number,
        .ssrc = sender.ssrc,
        .timestamp = packet.header.timestamp,
    };

    @memcpy(buffer[rtp_header_size .. packet.payload.len + rtp_header_size], packet.payload);
    std.mem.writeInt(u96, buffer[0..rtp_header_size], @bitCast(header), .big);
    try tr.transport.sendRtp(buffer[0 .. packet.payload.len + rtp_header_size]);
    sender.report.recordPacket(packet, timestamp);
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

fn sendAndRecord(tr: *RtpTransceiver, rtp_packet: *const rtp.Packet, buffer: []u8, timestamp: i64) !void {
    const payload_len = rtp_packet.payload.len;
    std.mem.writeInt(u96, buffer[0..rtp_header_size], @bitCast(rtp_packet.header), .big);
    try tr.transport.sendRtp(buffer[0 .. rtp_header_size + payload_len]);
    tr.sender.report.recordPacket(rtp_packet, timestamp);
}

fn microsecondsToNtp(timestamp: i64) u64 {
    const ntp_seconds = @divTrunc(timestamp, std.time.us_per_s) + webrtc.ntp_unix_epoch_diff;
    const ntp_fraction = @rem(timestamp, std.time.us_per_s);
    return @bitCast((ntp_seconds << 32) | ntp_fraction);
}

const testing = std.testing;

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
