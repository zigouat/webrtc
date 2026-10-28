const std = @import("std");
const webrtc = @import("webrtc.zig");

const PeerConnection = @import("peer_connection.zig");
const RtpSender = @import("rtp_sender.zig");
const RtpReceiver = @import("rtp_receiver.zig");
const InternalRtpTransceiver = @import("pc/internal_rtp_transceiver.zig");

const RtpTransceiver = @This();

pub const TransceiverID = u32;

pub const Direction = InternalRtpTransceiver.Direction;
pub const Init = InternalRtpTransceiver.Init;

pub const StopError = PeerConnection.ClosedError || std.mem.Allocator.Error;

id: TransceiverID,
pc: *PeerConnection,

pub fn getSender(transceiver: RtpTransceiver) RtpSender {
    return transceiver.pc.getRtpSender(transceiver.id);
}

pub fn getReceiver(transceiver: RtpTransceiver) RtpReceiver {
    return transceiver.pc.getRtpReceiver(transceiver.id);
}

pub fn getKind(transceiver: RtpTransceiver) webrtc.TrackKind {
    return transceiver.internal().kind;
}

/// Returns the preferred direction of the transceiver.
pub fn getDirection(transceiver: RtpTransceiver) Direction {
    return transceiver.internal().direction;
}

/// Returns the negotiated direction of the transceiver, or null if not negotiated yet or stopped.
pub fn getCurrentDirection(transceiver: RtpTransceiver) ?Direction {
    return transceiver.internal().current_direction;
}

pub fn isStopped(transceiver: RtpTransceiver) bool {
    return transceiver.internal().isStopped();
}

/// Stops the transceiver and checks if negotiation is needed.
pub fn stop(transceiver: RtpTransceiver) StopError!void {
    const pc = transceiver.pc;
    if (pc.connection_state == .closed) return error.ConnectionClosed;
    transceiver.internal().stop();
    try pc.checkNegotiationNeeded();
}

fn internal(self: RtpTransceiver) *InternalRtpTransceiver {
    return &self.pc.transceivers.items[self.id];
}
