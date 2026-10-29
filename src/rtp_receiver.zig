const std = @import("std");
const webrtc = @import("webrtc.zig");

const PeerConnection = @import("peer_connection.zig");
const DtlsTransport = @import("dtls_transport.zig");
const InternalRtpReceiver = @import("pc/internal_rtp_receiver.zig");

const RtpReceiver = @This();

pub const ReceiverID = u32;

pub const SendPliError = DtlsTransport.WriteMediaError;

id: ReceiverID,
pc: *PeerConnection,

/// Returns the remote track of the receiver.
pub fn getTrack(rtp_receiver: RtpReceiver) webrtc.MediaStreamTrack {
    return rtp_receiver.internal().track;
}

/// Sends a Picture Loss Indication (PLI) RTCP packet to the remote peer.
pub fn sendPli(rtp_receiver: RtpReceiver, buffer: []u8) SendPliError!webrtc.TransportMessage {
    const data = try rtp_receiver.internal().writePli(try rtp_receiver.pc.dtls_transport.rtcpPayloadBuffer(buffer));
    return try rtp_receiver.pc.dtls_transport.writeRtcp(buffer, data.len);
}

fn internal(self: RtpReceiver) *InternalRtpReceiver {
    return &self.pc.transceivers.items[self.id].receiver;
}
