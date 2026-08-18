const std = @import("std");
const webrtc = @import("webrtc.zig");
const rtp = @import("rtp");
const rtcp = @import("rtcp");

const Io = std.Io;
const RtpReceiver = @This();
const DtlsTransport = @import("dtls_transport.zig");

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
queue: Io.Queue(TrackEvent),
queue_buffer: []TrackEvent,
//Whether nack is configured for this receiver.
nack: bool,

pub fn init(allocator: std.mem.Allocator, track: webrtc.MediaStreamTrack) !RtpReceiver {
    const queue_buffer = try allocator.alloc(TrackEvent, queue_size);

    return .{
        .track = track,
        .queue = Io.Queue(TrackEvent).init(queue_buffer),
        .queue_buffer = queue_buffer,
        .ssrc = null,
        .stream_infos = @splat(null),
        .nack = false,
    };
}

pub fn deinit(receiver: *RtpReceiver, io: Io, allocator: std.mem.Allocator) void {
    receiver.queue.close(io);
    allocator.free(receiver.queue_buffer);
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

pub fn poll(receiver: *RtpReceiver, io: Io) !TrackEvent {
    return receiver.queue.getOne(io);
}

/// Deinitializes the event and frees any resources associated with it.
pub fn deinitEvent(receiver: *RtpReceiver, event: *const TrackEvent) void {
    const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("receiver", receiver));
    switch (event.*) {
        .rtp => |rtp_packet| {
            const header_size = rtp_packet.size() - rtp_packet.payload.len;
            const beg = rtp_packet.payload.ptr - header_size;
            tr.transport.ice_agent.destroyPacket(beg[0..1]);
        },
    }
}

pub fn handleRtpPacket(receiver: *RtpReceiver, io: Io, packet: rtp.Packet) !?rtp.Packet {
    const stream_info = receiver.stream_infos[packet.header.payload_type] orelse return null;
    if (stream_info.packet_type == .rtx) {
        @branchHint(.unlikely);
        return null;
    }

    if (receiver.ssrc != packet.header.ssrc) {
        @branchHint(.cold);
        receiver.ssrc = packet.header.ssrc;
    }

    try receiver.queue.putOne(io, .{ .rtp = packet });
    return packet;
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

test "RtpReceiver.init" {
    var receiver = try RtpReceiver.init(testing.allocator, .init(testing.io, .video));
    defer receiver.deinit(testing.io, testing.allocator);
}

test "RtpReceiver.poll" {
    var receiver = try RtpReceiver.init(testing.allocator, .init(testing.io, .video));
    defer receiver.deinit(testing.io, testing.allocator);

    receiver.setCodecs(&.{.{ .payload_type = 96, .mime_type = webrtc.MimeType.VP8, .clock_rate = 90000 }});

    const packet = testPacket(96);

    _ = try receiver.handleRtpPacket(testing.io, packet);
    const event = try receiver.poll(testing.io);
    try testing.expectEqual(.rtp, std.meta.activeTag(event));
    try testing.expectEqual(packet.header.ssrc, event.rtp.header.ssrc);

    try testing.expectEqual(receiver.ssrc.?, packet.header.ssrc);
}

test "RtpReceiver.setCodecs: fill stream infos" {
    var receiver = try RtpReceiver.init(testing.allocator, .init(testing.io, .video));
    defer receiver.deinit(testing.io, testing.allocator);

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
    var receiver = try RtpReceiver.init(testing.allocator, .init(testing.io, .video));
    defer receiver.deinit(testing.io, testing.allocator);

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

test "RtpReceiver.handleRtpPacket: ignore packets not satisfying stream info" {
    var receiver = try RtpReceiver.init(testing.allocator, .init(testing.io, .video));
    defer receiver.deinit(testing.io, testing.allocator);

    receiver.stream_infos[96] = .{ .packet_type = .media, .apt = 0 };
    receiver.stream_infos[97] = .{ .packet_type = .rtx, .apt = 96 };

    var packet = testPacket(97);
    _ = try receiver.handleRtpPacket(testing.io, packet); // ignore rtx packet

    var events: [1]TrackEvent = undefined;
    const received = try receiver.queue.get(testing.io, &events, 0);
    try testing.expectEqual(0, received);

    packet.header.payload_type = 104;
    _ = try receiver.handleRtpPacket(testing.io, packet); // ignore unknown payload type
    try testing.expectEqual(0, try receiver.queue.get(testing.io, &events, 0));
}
