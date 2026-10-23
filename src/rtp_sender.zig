const std = @import("std");
const webrtc = @import("webrtc.zig");
const rtp = @import("rtp");
const media = @import("media");

const PeerConnection = @import("peer_connection.zig");
const InternalRtpSender = @import("pc/internal_rtp_sender.zig");

/// A handle to the sender of a transceiver.
///
/// The handle identifies the transceiver, not the track. After `PeerConnection.removeTrack`
/// the handle is invalid: a later `addTrack` may reuse the same transceiver, and the old
/// handle would then send on the new track. It's up to the application to drop handles
/// of removed tracks.
const RtpSender = @This();

pub const SenderID = u32;

/// Packetizes and encrypts a media sample.
///
/// Holds a pointer into the peer connection's transceivers. Adding transceivers (`addTrack`,
/// `addTransceiver*`, applying a remote description) invalidates it; finish iterating
/// before making any such call.
pub const MediaPacketWriterIterator = struct {
    pc: *PeerConnection,
    writer: InternalRtpSender.SamplePacketizerIterator,

    pub fn init(sender: RtpSender, media_packet: *const media.Packet) !MediaPacketWriterIterator {
        return .{
            .pc = sender.pc,
            .writer = try sender.internal().handleMediaPacketWrite(media_packet),
        };
    }

    pub fn next(it: *MediaPacketWriterIterator, buffer: []u8, now_us: i64) !?webrtc.TransportMessage {
        const packet = try it.writer.next(buffer, now_us) orelse return null;
        return try it.pc.dtls_transport.writeRtp(buffer, packet.len);
    }
};

id: SenderID,
pc: *PeerConnection,

/// Returns the track currently attached to the sender, if any.
pub fn getTrack(rtp_sender: RtpSender) ?webrtc.MediaStreamTrack {
    return rtp_sender.internal().track;
}

pub fn sendRtp(rtp_sender: RtpSender, packet: *const rtp.Packet, buffer: []u8, now_micro: i64) !webrtc.TransportMessage {
    const data = try rtp_sender.internal().handleWrite(packet, buffer, now_micro);
    return try rtp_sender.pc.dtls_transport.writeRtp(buffer, data.len);
}

pub fn sendSample(rtp_sender: RtpSender, sample: *const media.Packet) !MediaPacketWriterIterator {
    return try MediaPacketWriterIterator.init(rtp_sender, sample);
}

fn internal(self: RtpSender) *InternalRtpSender {
    return &self.pc.transceivers.items[self.id].sender;
}
