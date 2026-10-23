const std = @import("std");
const webrtc = @import("webrtc.zig");

const PeerConnection = @import("peer_connection.zig");
const InternalRtpReceiver = @import("pc/internal_rtp_receiver.zig");

const RtpReceiver = @This();

pub const ReceiverID = u32;

id: ReceiverID,
pc: *PeerConnection,

/// Sends a Picture Loss Indication (PLI) RTCP packet to the remote peer.
pub fn sendPli(rtp_receiver: RtpReceiver, buffer: []u8) !webrtc.TransportMessage {
    const data = rtp_receiver.internal().writePli(buffer);
    const to_send = try rtp_receiver.pc.dtls_transport.handleMediaWrite(buffer, data.len, false);
    return toTransportMessage(rtp_receiver.pc, to_send);
}

fn internal(self: RtpReceiver) *InternalRtpReceiver {
    return &self.pc.transceivers.items[self.id].receiver;
}

fn toTransportMessage(pc: *PeerConnection, data: []const u8) webrtc.TransportMessage {
    const from, const to = pc.dtls_transport.nominated_pair.?;
    return .{ .data = data, .from = from, .to = to };
}
