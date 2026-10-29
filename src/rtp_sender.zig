const std = @import("std");
const webrtc = @import("webrtc.zig");
const rtp = @import("rtp");
const media = @import("media");

const PeerConnection = @import("peer_connection.zig");
const DtlsTransport = @import("dtls_transport.zig");
const InternalRtpSender = @import("pc/internal_rtp_sender.zig");

/// A handle to the sender of a transceiver.
///
/// The handle identifies the transceiver, not the track. After `PeerConnection.removeTrack`
/// the handle is invalid: a later `addTrack` may reuse the same transceiver, and the old
/// handle would then send on the new track. It's up to the application to drop handles
/// of removed tracks.
const RtpSender = @This();

pub const SenderID = u32;

pub const StateError = InternalRtpSender.StateError;
pub const SendRtpError = InternalRtpSender.WriteError || DtlsTransport.WriteRtpError;
pub const SendSampleError = StateError;

/// Packetizes and encrypts a media sample.
///
/// Holds a pointer into the peer connection's transceivers. Adding transceivers (`addTrack`,
/// `addTransceiver*`, applying a remote description) invalidates it; finish iterating
/// before making any such call.
pub const MediaPacketWriterIterator = struct {
    pub const NextError = InternalRtpSender.PacketizeError || std.mem.Allocator.Error;

    pc: *PeerConnection,
    writer: InternalRtpSender.SamplePacketizerIterator,

    pub fn init(sender: RtpSender, media_packet: *const media.Packet) SendSampleError!MediaPacketWriterIterator {
        return .{
            .pc = sender.pc,
            .writer = try sender.internal().handleMediaPacketWrite(media_packet),
        };
    }

    pub fn next(it: *MediaPacketWriterIterator, buffer: []u8, now_us: i64) NextError!?webrtc.TransportMessage {
        const writable_buffer = try it.pc.dtls_transport.payloadBuffer(buffer);
        const packet = try it.writer.next(writable_buffer, now_us) orelse return null;
        return it.pc.dtls_transport.writeRtp(buffer, packet.len) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => unreachable,
        };
    }
};

id: SenderID,
pc: *PeerConnection,

/// Returns the track currently attached to the sender, if any.
pub fn getTrack(rtp_sender: RtpSender) ?webrtc.MediaStreamTrack {
    return rtp_sender.internal().track;
}

pub fn sendRtp(rtp_sender: RtpSender, packet: *const rtp.Packet, buffer: []u8, now_micro: i64) SendRtpError!webrtc.TransportMessage {
    const writable_buffer = try rtp_sender.pc.dtls_transport.payloadBuffer(buffer);
    const data = try rtp_sender.internal().handleWrite(packet, writable_buffer, now_micro);
    return try rtp_sender.pc.dtls_transport.writeRtp(buffer, data.len);
}

pub fn sendSample(rtp_sender: RtpSender, sample: *const media.Packet) SendSampleError!MediaPacketWriterIterator {
    return try MediaPacketWriterIterator.init(rtp_sender, sample);
}

fn internal(self: RtpSender) *InternalRtpSender {
    return &self.pc.transceivers.items[self.id].sender;
}
