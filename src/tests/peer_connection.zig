const std = @import("std");
const PeerConnection = @import("../peer_connection.zig");
const webrtc = @import("../webrtc.zig");

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

    _ = try pc.addTrack(.initWithId("video-track", .video));
    _ = try pc.addTrack(.initWithId("audio-track", .audio));

    offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
}

test "addTrack" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const track: webrtc.MediaStreamTrack = .init(testing.io, .video);

    _ = try pc.addTrack(track);
    try std.testing.expectEqual(1, pc.transceivers.items.len);

    const tr = try pc.addTransceiverFromKind(.video, .{ .direction = .recvonly });
    try std.testing.expect(tr.sender.track == null);

    const sender = try pc.addTrack(.initWithId("track2", .video));
    try std.testing.expectEqual(sender, &tr.sender);
    try std.testing.expectEqual(2, pc.transceivers.items.len);
    try std.testing.expect(tr.sender.track != null);
    try std.testing.expectEqualStrings("track2", tr.sender.track.?.getId());
}

test "removeTrack" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const sender = try pc.addTrack(.initWithId("track1", .video));
    try pc.removeTrack(sender);

    const tr = pc.getTransceivers()[0];

    try testing.expect(sender.track == null);
    try testing.expect(tr.sender.track == null);
    try testing.expectEqual(.recvonly, tr.direction);
}

test "addTransceiver" {
    {
        var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
        defer pc.deinit();

        const track: webrtc.MediaStreamTrack = .initWithId("track1", .video);

        const tr = try pc.addTransceiverFromTrack(track, .{ .direction = .sendrecv });
        try std.testing.expectEqual(1, pc.transceivers.items.len);
        try std.testing.expectEqual(.sendrecv, tr.direction);
        try std.testing.expectEqualStrings(&track.id, &tr.sender.track.?.id);

        const tr2 = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
        try std.testing.expectEqual(2, pc.transceivers.items.len);
        try std.testing.expectEqual(.recvonly, tr2.direction);
        try std.testing.expect(tr2.sender.track == null);
    }

    {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 5 });
        var pc = try PeerConnection.init(testing.io, failing_alloc.allocator(), .{});
        defer pc.deinit();

        try std.testing.expectError(error.OutOfMemory, pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly }));
    }
}

test "Negotiate between peers" {
    var pc1: PeerConnection = try .init(io, allocator, .{ .inner_queue_size = 20 });
    defer pc1.deinit();

    var pc2: PeerConnection = try .init(io, allocator, .{ .inner_queue_size = 20 });
    defer pc2.deinit();

    const track1: webrtc.MediaStreamTrack = .init(testing.io, .video);

    _ = try pc1.addTrack(track1);
    _ = try pc1.addTrack(.init(testing.io, .video));

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

    // pc2 track events
    for (0..2) |_| {
        const event = try pc2.poll();
        try testing.expectEqual(.track_event, std.meta.activeTag(event));
    }

    for (0..10) |_| {
        const screen1 = try pc1.addTrack(.initWithId("screenshare", .video));
        const screen2 = try pc2.addTrack(.initWithId("screenshare", .video));
        try negotiate(&pc1, &pc2);

        try testing.expectEqual(3, pc1.getTransceivers().len);
        try testing.expectEqual(3, pc2.getTransceivers().len);

        const event = try pc1.poll();
        try testing.expectEqual(.track_event, std.meta.activeTag(event));
        // screenshare is linked to video1
        try testing.expectEqualStrings(track1.getId(), event.track_event.track.getId());

        try pc1.removeTrack(screen1);
        try pc2.removeTrack(screen2);
        try negotiate(&pc1, &pc2);
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
