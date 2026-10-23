const std = @import("std");
const webrtc = @import("webrtc.zig");
const constants = @import("constants.zig");
const rtp = @import("rtp");
const media = @import("media");

const PeerConnection = @import("peer_connection.zig");
const InternalRtpSender = @import("pc/internal_rtp_sender.zig");

const RtpSender = @This();

pub const SenderID = u32;

pub const MediaPacketWriterIterator = struct {
    rtp_sender: RtpSender,
    writer: InternalRtpSender.SamplePacketizerIterator,

    pub fn init(sender: RtpSender, media_packet: *const media.Packet) !MediaPacketWriterIterator {
        const sender_internal = sender.internal();
        return MediaPacketWriterIterator{
            .rtp_sender = sender,
            .writer = try sender_internal.handleMediaPacketWrite(media_packet),
        };
    }

    pub fn next(it: *MediaPacketWriterIterator, buffer: []u8, now_us: i64) !?webrtc.TransportMessage {
        const packet = try it.writer.next(buffer, now_us) orelse return null;
        return toTransportMessage(it.rtp_sender.pc, try it.rtp_sender.pc.dtls_transport.handleMediaWrite(
            buffer,
            packet.len,
            true,
        ));
    }
};

id: SenderID,
pc: *PeerConnection,

pub fn sendRtp(rtp_sender: *RtpSender, packet: *const rtp.Packet, buffer: []u8, now_micro: i64) !webrtc.TransportMessage {
    const data = try rtp_sender.internal().handleWrite(packet, buffer, now_micro);
    const to_send = try rtp_sender.pc.dtls_transport.handleMediaWrite(buffer, data.len, true);
    return toTransportMessage(rtp_sender.pc, to_send);
}

pub fn sendSample(rtp_sender: RtpSender, sample: *const media.Packet) !MediaPacketWriterIterator {
    return try MediaPacketWriterIterator.init(rtp_sender, sample);
}

fn internal(self: RtpSender) *InternalRtpSender {
    return &self.pc.transceivers.items[self.id].sender;
}

fn toTransportMessage(pc: *PeerConnection, data: []const u8) webrtc.TransportMessage {
    const from, const to = pc.dtls_transport.nominated_pair.?;
    return .{ .data = data, .from = from, .to = to };
}
