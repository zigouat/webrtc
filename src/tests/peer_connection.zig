const std = @import("std");
const PeerConnection = @import("../peer_connection.zig");
const webrtc = @import("../webrtc.zig");
const SDPSession = @import("../sdp_session.zig");

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

    const event = try pc.poll();
    try std.testing.expectEqual(.signaling_state, std.meta.activeTag(event));
    try std.testing.expectEqual(.have_local_offer, event.signaling_state);
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

test "createOffer: empty offer" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.desc_type);

    const sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    try testing.expectEqual(0, sdp_session.getMedias().len);
}

test "createOffer: m-lines created for each transceiver" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    _ = try pc.addTrack(.initWithId("video", .video));
    _ = try pc.addTrack(.initWithId("audio", .audio));
    _ = try pc.addTrack(.initWithId("video", .video));

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.desc_type);

    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    try testing.expectEqual(3, sdp_session.getMedias().len);
    const transceivers = pc.getTransceivers();
    const medias = sdp_session.getMedias();
    for (transceivers, medias, 0..) |tr, media, idx| {
        try testing.expectEqual(media.kind, tr.kind);
        try testing.expectEqual(idx, tr.sdp_mline_index.?);
        try testing.expect(media.getMid().len != 0);
    }
}

test "createOffer: stopped non-associted transceiver is ignored" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const tr = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
    tr.stop();

    _ = try pc.addTrack(.initWithId("video", .video));

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.desc_type);

    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    try testing.expectEqual(1, sdp_session.getMedias().len);
}

test "createOffer: multiple offers" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    _ = try pc.addTrack(.initWithId("video", .video));
    _ = try pc.addTrack(.initWithId("audio", .audio));

    var offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
    pc.getTransceivers()[1].stop();

    offer = try pc.createOffer();
    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    try testing.expectEqual(2, sdp_session.getMedias().len);
    try testing.expect(sdp_session.getMedias()[1].port == 0);
    const old_mid = sdp_session.getMedias()[1].mid;

    try pc.setLocalDescription(offer);
    _ = try pc.addTrack(.initWithId("video2", .video));

    offer = try pc.createOffer();
    sdp_session.deinit(testing.allocator);
    sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    // Test media recycling
    try testing.expectEqual(2, sdp_session.getMedias().len);
    try testing.expect(sdp_session.getMedias()[1].port != 0);
    try testing.expect(!std.mem.eql(u8, &old_mid, sdp_session.getMedias()[1].getMid()));
}

test "Negotiate between peers" {
    var pc1: PeerConnection = try .init(io, allocator, .{ .inner_queue_size = 1 });
    defer pc1.deinit();

    var pc2: PeerConnection = try .init(io, allocator, .{ .inner_queue_size = 1 });
    defer pc2.deinit();

    var pc1_collector: EventCollector = .{};
    var pc2_collector: EventCollector = .{};
    defer pc1_collector.deinit();
    defer pc2_collector.deinit();

    try pc1_collector.collect(&pc1);
    try pc2_collector.collect(&pc2);

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
    var event_idx = pc2_collector.findEvent(0, .track_event);
    try testing.expect(event_idx != null);
    event_idx = pc2_collector.findEvent(event_idx.? + 1, .track_event);
    try testing.expect(event_idx != null);
    event_idx = pc2_collector.findEvent(event_idx.? + 1, .track_event);
    try testing.expect(event_idx == null);

    for (0..10) |_| {
        const screen1 = try pc1.addTrack(.initWithId("screenshare", .video));
        const screen2 = try pc2.addTrack(.initWithId("screenshare", .video));
        try negotiate(&pc1, &pc2);

        try testing.expectEqual(3, pc1.getTransceivers().len);
        try testing.expectEqual(3, pc2.getTransceivers().len);

        event_idx = pc1_collector.findEvent(0, .track_event);
        try testing.expect(event_idx != null);
        event_idx = pc2_collector.findEvent(0, .track_event);
        try testing.expect(event_idx != null);

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

const EventCollector = struct {
    group: std.Io.Group = .init,
    events: std.ArrayList(PeerConnection.Event) = .empty,

    fn deinit(collector: *EventCollector) void {
        collector.group.cancel(io);
        collector.events.deinit(allocator);
    }

    fn collect(collector: *EventCollector, pc: *PeerConnection) !void {
        try collector.group.concurrent(io, collectEvents, .{ collector, pc });
    }

    fn collectEvents(collector: *EventCollector, pc: *PeerConnection) !void {
        while (pc.poll()) |event| {
            collector.events.append(allocator, event) catch return;
        } else |_| {}
    }

    fn findEvent(collector: *const EventCollector, pos: usize, event_type: @typeInfo(PeerConnection.Event).@"union".tag_type.?) ?usize {
        for (collector.events.items[pos..], pos..) |event, idx| if (std.meta.activeTag(event) == event_type) return idx;
        return null;
    }
};
