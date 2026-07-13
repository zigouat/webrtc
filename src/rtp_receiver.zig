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

track: webrtc.MediaStreamTrack,
codecs: []const webrtc.RtpCodecParameters = &.{},
ssrc: u32,
queue: Io.Queue(TrackEvent),
queue_buffer: []TrackEvent,

pub fn init(track: webrtc.MediaStreamTrack, allocator: std.mem.Allocator) !RtpReceiver {
    const queue_buffer = try allocator.alloc(TrackEvent, queue_size);

    return .{
        .track = track,
        .queue = .init(queue_buffer),
        .queue_buffer = queue_buffer,
        .ssrc = 0,
    };
}

pub fn deinit(receiver: *RtpReceiver, io: Io, allocator: std.mem.Allocator) void {
    receiver.queue.close(io);
    allocator.free(receiver.queue_buffer);
}

pub fn poll(receiver: *RtpReceiver, io: Io) !TrackEvent {
    return receiver.queue.getOne(io);
}

/// Deinitializes the event and frees any resources associated with it.
pub fn deinitEvent(reciever: *RtpReceiver, event: *const TrackEvent) void {
    const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("receiver", reciever));
    switch (event.*) {
        .rtp => |rtp_packet| {
            const header_size: u8 = @intCast(rtp_packet.size() - rtp_packet.payload.len);
            const beg = rtp_packet.payload.ptr - header_size;
            tr.transport.ice_agent.destroyPacket(beg[0..1]);
        },
    }
}

pub fn handleRtpPacket(receiver: *RtpReceiver, io: Io, packet: rtp.Packet) !void {
    if (receiver.ssrc == 0) {
        @branchHint(.cold);
        receiver.ssrc = packet.header.ssrc;
    }
    try receiver.queue.putOne(io, .{ .rtp = packet });
}

/// Sends a Picture Loss Indication (PLI) RTCP packet to the remote peer.
pub fn sendPli(receiver: *RtpReceiver) DtlsTransport.SendError!void {
    // 4 bytes header + PLI size is 8 bytes
    var buffer: [12]u8 = undefined;
    const header: rtcp.Header = .{ .rc = 1, .payload_type = .ps_fb, .length = 2, .padding = false };
    std.mem.writeInt(u32, buffer[0..4], @bitCast(header), .big);
    (rtcp.PLI{ .sender_ssrc = 0, .media_ssrc = receiver.ssrc }).encode(buffer[4..12]);

    const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("receiver", receiver));
    try tr.transport.sendRtcp(&buffer);
}

const testing = std.testing;

test "init" {
    var receiver = try RtpReceiver.init(.init(testing.io, .video), testing.allocator);
    defer receiver.deinit(testing.io, testing.allocator);
}

test "poll" {
    var receiver = try RtpReceiver.init(.init(testing.io, .video), testing.allocator);
    defer receiver.deinit(testing.io, testing.allocator);

    const packet: rtp.Packet = .{
        .header = .{
            .ssrc = 0,
            .timestamp = 1000,
            .sequence_number = 10,
            .payload_type = 96,
            .marker = false,
            .extension = false,
            .padding = false,
        },
        .payload = "hello",
    };

    try receiver.handleRtpPacket(testing.io, packet);
    const event = try receiver.poll(testing.io);
    try testing.expectEqual(.rtp, std.meta.activeTag(event));
    try testing.expectEqual(packet.header.ssrc, event.rtp.header.ssrc);
}
