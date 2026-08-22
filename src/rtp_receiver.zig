const std = @import("std");
const webrtc = @import("webrtc.zig");
const rtp = @import("rtp");
const rtcp = @import("rtcp");

const Io = std.Io;
const RtpReceiver = @This();
const DtlsTransport = @import("dtls_transport.zig");
const Callback = *const fn (userdata: ?*anyopaque, receiver: *RtpReceiver, event: TrackEvent) void;

const queue_size: usize = 16;

/// TrackEvent represents events related to a remote track.
pub const TrackEvent = union(enum) {
    rtp: rtp.Packet,
};

const StreamInfo = packed struct {
    packet_type: enum(u1) { media, rtx },
    apt: u7,
};

track: webrtc.MediaStreamTrack,
codecs: []const webrtc.RtpCodecParameters = &.{},
stream_infos: [128]?StreamInfo,
header_extensions: []const webrtc.RtpHeaderExtensionParameter = &.{},
ssrc: ?u32,
//Whether nack is configured for this receiver.
nack: bool,

user_data: ?*anyopaque = null,
on_track_event: ?Callback = null,

pub fn init(track: webrtc.MediaStreamTrack) RtpReceiver {
    return .{
        .track = track,
        .ssrc = null,
        .stream_infos = @splat(null),
        .nack = false,
    };
}

pub fn setCodecs(receiver: *RtpReceiver, codecs: []const webrtc.RtpCodecParameters) void {
    receiver.codecs = codecs;

    receiver.stream_infos = @splat(null);
    receiver.nack = false;
    for (receiver.codecs) |*codec| {
        receiver.stream_infos[codec.payload_type] = .{
            .packet_type = if (codec.isRtx()) .rtx else .media,
            .apt = if (codec.isRtx()) @intCast(codec.fmtp_params.?.rtx.apt) else 0,
        };

        receiver.nack |= codec.rtcp_feedbacks.nack;
    }
}

pub fn handleRtpPacket(receiver: *RtpReceiver, packet: *rtp.Packet) !bool {
    const stream_info = receiver.stream_infos[packet.header.payload_type] orelse return false;
    if (stream_info.packet_type == .rtx) {
        @branchHint(.unlikely);
        if (packet.payload.len < 2 or receiver.ssrc == null) return false;
        std.log.debug("ssrc={} pt={} received rtx packet", .{ receiver.ssrc.?, packet.header.payload_type });

        const payload = @constCast(packet.payload);
        const original_seq = std.mem.readInt(u16, payload[0..2], .big);
        @memmove(payload[0 .. payload.len - 2], payload[2..payload.len]);

        packet.header.payload_type = stream_info.apt;
        packet.header.sequence_number = original_seq;
        packet.header.ssrc = receiver.ssrc.?;
        packet.payload = payload[0 .. payload.len - 2];
    }

    if (receiver.ssrc != packet.header.ssrc) {
        @branchHint(.cold);
        receiver.ssrc = packet.header.ssrc;
    }

    if (receiver.on_track_event) |callback| {
        @branchHint(.likely);
        callback(receiver.user_data, receiver, .{ .rtp = packet.* });
    }

    return true;
}

/// Sends a Picture Loss Indication (PLI) RTCP packet to the remote peer.
pub fn sendPli(receiver: *RtpReceiver) DtlsTransport.SendError!void {
    // 4 bytes header + PLI size is 8 bytes
    var buffer: [12]u8 = undefined;
    const header: rtcp.Header = .{ .rc = 1, .payload_type = .ps_fb, .length = 2, .padding = false };
    std.mem.writeInt(u32, buffer[0..4], @bitCast(header), .big);
    (rtcp.PLI{ .sender_ssrc = 0, .media_ssrc = receiver.ssrc orelse 0 }).encode(buffer[4..12]);

    const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("receiver", receiver));
    try tr.transport.sendRtcp(&buffer);
}

pub fn registerCallback(receiver: *RtpReceiver, userdata: ?*anyopaque, callback: Callback) void {
    receiver.user_data = userdata;
    receiver.on_track_event = callback;
}

const testing = std.testing;

fn testPacket(pt: u7) rtp.Packet {
    return .{
        .header = .{
            .ssrc = 0,
            .timestamp = 1000,
            .sequence_number = 10,
            .payload_type = pt,
            .marker = false,
            .extension = false,
            .padding = false,
        },
        .payload = "hello",
    };
}

test "RtpReceiver.setCodecs: fill stream infos" {
    var receiver = RtpReceiver.init(.init(testing.io, .video));

    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .mime_type = webrtc.MimeType.VP8, .clock_rate = 90000 },
        .{ .payload_type = 104, .mime_type = webrtc.MimeType.H264, .clock_rate = 90000 },
        .{
            .payload_type = 97,
            .mime_type = webrtc.MimeType.Rtx,
            .clock_rate = 90000,
            .fmtp_params = .{ .rtx = .{ .apt = 96 } },
        },
    };

    receiver.setCodecs(&codecs);

    var stream_info = receiver.stream_infos[96];
    try testing.expect(stream_info != null);
    try testing.expectEqual(.media, stream_info.?.packet_type);
    try testing.expectEqual(0, stream_info.?.apt);

    stream_info = receiver.stream_infos[97];
    try testing.expect(stream_info != null);
    try testing.expectEqual(.rtx, stream_info.?.packet_type);
    try testing.expectEqual(96, stream_info.?.apt);

    stream_info = receiver.stream_infos[104];
    try testing.expect(stream_info != null);
    try testing.expectEqual(.media, stream_info.?.packet_type);

    for (0..128) |pt| {
        switch (pt) {
            96, 97, 104 => {},
            else => try testing.expect(receiver.stream_infos[pt] == null),
        }
    }
}

test "RtpReceiver.setCodecs: clear stream infos before filling" {
    var receiver = RtpReceiver.init(.init(testing.io, .video));

    const codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .mime_type = webrtc.MimeType.VP8, .clock_rate = 90000 },
        .{ .payload_type = 104, .mime_type = webrtc.MimeType.H264, .clock_rate = 90000 },
        .{
            .payload_type = 97,
            .mime_type = webrtc.MimeType.Rtx,
            .clock_rate = 90000,
            .fmtp_params = .{ .rtx = .{ .apt = 96 } },
        },
    };

    receiver.setCodecs(&codecs);

    for (0..128) |pt| {
        switch (pt) {
            96, 97, 104 => try testing.expect(receiver.stream_infos[pt] != null),
            else => try testing.expect(receiver.stream_infos[pt] == null),
        }
    }

    receiver.setCodecs(codecs[1..2]);
    for (0..128) |pt| {
        switch (pt) {
            104 => try testing.expect(receiver.stream_infos[pt] != null),
            else => try testing.expect(receiver.stream_infos[pt] == null),
        }
    }
}

test "RtpReceiver.handleRtpPacket: handle rtx packets" {
    var receiver = RtpReceiver.init(.init(testing.io, .video));

    receiver.stream_infos[96] = .{ .packet_type = .media, .apt = 0 };
    receiver.stream_infos[97] = .{ .packet_type = .rtx, .apt = 96 };

    // Ignore rtx packets when ssrc is not yet known (no rtp packet is received yet)
    var rtx_packet = testPacket(97);
    try testing.expect(!(try receiver.handleRtpPacket(&rtx_packet)));

    var packet = testPacket(96);
    packet.header.sequence_number = 1000;
    packet.header.ssrc = 0xDEADDEAD;
    try testing.expect(try receiver.handleRtpPacket(&packet));

    var payload: [10]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 1001, .big);
    @memcpy(payload[2..], "ZIGLANG-");
    rtx_packet.payload = payload[0..];
    rtx_packet.header.sequence_number = 2;
    try testing.expect(try receiver.handleRtpPacket(&rtx_packet));

    try testing.expectEqual(96, rtx_packet.header.payload_type);
    try testing.expectEqual(0xDEADDEAD, rtx_packet.header.ssrc);
    try testing.expectEqual(1001, rtx_packet.header.sequence_number);
    try testing.expectEqualStrings("ZIGLANG-", rtx_packet.payload);
}

test "RtpReceiver.handleRtpPacket: ignore packets with unknown payload type" {
    var receiver = RtpReceiver.init(.init(testing.io, .video));
    receiver.stream_infos[96] = .{ .packet_type = .media, .apt = 0 };

    var packet = testPacket(104);
    try testing.expect(!(try receiver.handleRtpPacket(&packet)));
}
