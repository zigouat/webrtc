//! This file defines the Handler struct, which is used to handle events from the PeerConnection.

const std = @import("std");
const ice = @import("ice");
const PeerConnection = @import("../peer_connection.zig");
const RtpTransceiver = @import("../webrtc.zig").RtpTransceiver;

const Handler = @This();

userdata: ?*anyopaque,
vtable: *const VTable,

const VTable = struct {
    /// Called when the PeerConnection needs to renegotiate the session.
    onNegotiationNeeded: *const fn (?*anyopaque) void = onNegotiationNeeded,
    /// Called when the signaling state of the PeerConnection changes.
    onSignalingStateChange: *const fn (?*anyopaque, PeerConnection.SignalingState) void = onSignalingStateChange,
    /// Called when the connection state of the PeerConnection changes.
    onConnectionStateChange: *const fn (?*anyopaque, PeerConnection.ConnectionState) void = onConnectionStateChange,
    /// Called when the ICE gathering state of the PeerConnection changes.
    onGatheringStateChange: *const fn (?*anyopaque, PeerConnection.GatheringState) void = onGatheringStateChange,
    /// Called when a new remote track is added to the PeerConnection.
    onTrack: *const fn (?*anyopaque, RtpTransceiver.TrackEventInit) void = onTrack,
    /// Called when a new ICE candidate is found.
    onIceCandidate: *const fn (?*anyopaque, ?ice.Candidate) void = onIceCandidate,
};

fn onNegotiationNeeded(userdata: ?*anyopaque) void {
    _ = userdata;
}

fn onSignalingStateChange(userdata: ?*anyopaque, state: PeerConnection.SignalingState) void {
    _ = userdata;
    _ = state;
}

fn onConnectionStateChange(userdata: ?*anyopaque, state: PeerConnection.ConnectionState) void {
    _ = userdata;
    _ = state;
}

fn onGatheringStateChange(userdata: ?*anyopaque, state: PeerConnection.GatheringState) void {
    _ = userdata;
    _ = state;
}

fn onTrack(userdata: ?*anyopaque, event: RtpTransceiver.TrackEventInit) void {
    _ = userdata;
    _ = event;
}

fn onIceCandidate(userdata: ?*anyopaque, candidate: ?ice.Candidate) void {
    _ = userdata;
    _ = candidate;
}
