const std = @import("std");
const PeerConnection = @import("../peer_connection.zig");

const testing = std.testing;
const io = testing.io;
const allocator = testing.allocator;

test "init" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();
}

test "setLocalDescription: set offer" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
}

test "setLocalDescription: set offer multiple times" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    var offer = try pc.createOffer();
    try pc.setLocalDescription(offer);

    try pc.addTrack(.{ .id = "video-track", .kind = .video });
    try pc.addTrack(.{ .id = "audio-track", .kind = .audio });

    offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
}

test "Negotiate between peers" {
    var pc1: PeerConnection = try .init(io, allocator, .{});
    defer pc1.deinit();

    var pc2: PeerConnection = try .init(io, allocator, .{});
    defer pc2.deinit();

    try pc1.addTrack(.{ .id = "video1", .kind = .video });
    try pc1.addTrack(.{ .id = "video2", .kind = .video });

    try negotiate(&pc1, &pc2);

    const pc1_transceivers = pc1.transceivers.items;
    const pc2_transceivers = pc2.transceivers.items;

    try testing.expectEqual(2, pc1_transceivers.len);
    try testing.expectEqual(2, pc2_transceivers.len);

    for (pc1_transceivers) |tr| {
        try testing.expectEqual(.video, tr.kind);
        try testing.expectEqual(.sendrecv, tr.direction);
        try testing.expectEqual(.sendonly, tr.current_direction);
    }

    for (pc2_transceivers) |tr| {
        try testing.expectEqual(.video, tr.kind);
        try testing.expectEqual(.recvonly, tr.direction);
        try testing.expectEqual(.recvonly, tr.current_direction);
    }
}

fn negotiate(pc1: *PeerConnection, pc2: *PeerConnection) !void {
    const offer = try pc1.createOffer();
    try pc1.setLocalDescription(offer);
    try pc2.setRemoteDescription(offer);

    const answer = try pc2.createAnswer();
    try pc2.setLocalDescription(answer);
    try pc1.setRemoteDescription(answer);
}
