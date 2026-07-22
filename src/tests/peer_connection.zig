const std = @import("std");
const PeerConnection = @import("../peer_connection.zig");
const webrtc = @import("../webrtc.zig");
const SDPSession = @import("../sdp_session.zig");

const testing = std.testing;
const PCEvent = @typeInfo(PeerConnection.Event).@"union".tag_type.?;

const io = testing.io;
const allocator = testing.allocator;

test "init" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();
}

test "addTransceiverFromKind: no leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var pc = try PeerConnection.init(io, alloc, .{});
            defer pc.deinit();
            _ = try pc.addTransceiverFromKind(.video, .{ .direction = .sendrecv, .stream_id = "stream" });
        }
    }.run, .{});
}

test "setLocalDescription: set offer" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const offer = try pc.createOffer();
    try pc.setLocalDescription(offer);

    while (true) {
        switch (try pc.poll()) {
            .signaling_state => |state| {
                try std.testing.expectEqual(.have_local_offer, state);
                break;
            },
            else => {},
        }
    }
}

test "setLocalDescription: set offer multiple times" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    var offer = try pc.createOffer();
    try pc.setLocalDescription(offer);

    _ = try pc.addTrack(.initWithId("video-track", .video), null);
    _ = try pc.addTrack(.initWithId("audio-track", .audio), null);

    offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
}

test "setLocalDescription: invalid state" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    try testing.expectError(error.NotImplemented, pc.setLocalDescription(.{ .type = .pranswer, .sdp = "" }));
    try testing.expectError(error.NotImplemented, pc.setLocalDescription(.{ .type = .rollback, .sdp = "" }));
    try testing.expectError(error.InvalidState, pc.setLocalDescription(.{ .type = .answer, .sdp = "" }));

    const sdp = (try pc.createOffer()).sdp;
    try pc.setLocalDescription(.{ .type = .offer, .sdp = sdp });
    try testing.expectError(error.InvalidState, pc.setLocalDescription(.{ .type = .answer, .sdp = sdp }));

    try pc.setRemoteDescription(.{ .type = .answer, .sdp = sdp });
    try pc.setRemoteDescription(.{ .type = .offer, .sdp = sdp });
    try testing.expectError(error.InvalidState, pc.setLocalDescription(.{ .type = .offer, .sdp = sdp }));
}

test "setRemoteDescription: set offer" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const offer =
        \\v=0
        \\o=- 1000 1779396395 IN IP4 0.0.0.0
        \\s=-
        \\t=0 0
        \\a=group:BUNDLE 0
        \\a=ice-options:ice2 
        \\a=fingerprint:sha-256 A4:14:A3:5D:02:35:5B:E0:C6:E0:EF:7D:D9:63:3F:30:D4:FD:43:76:50:A8:25:4A:96:25:F1:8A:0A:DC:F4:26
        \\m=video 9 UDP/TLS/RTP/SAVPF 96
        \\c=IN IP4 0.0.0.0
        \\a=rtpmap:96 VP8/90000
        \\a=fmtp:96 max-fs=12288;max-fr=60
        \\a=setup:actpass
        \\a=sendrecv
        \\a=mid:0
        \\a=rtcp-mux
        \\a=ice-ufrag:elsfVzJM
        \\a=ice-pwd:/KLNLMQnQm5TWswZ9MAnalyn
        \\
    ;

    try pc.setRemoteDescription(.{ .type = .offer, .sdp = offer });

    const event = try pc.poll();
    try std.testing.expectEqual(.signaling_state, std.meta.activeTag(event));
    try std.testing.expectEqual(.have_remote_offer, event.signaling_state);
}

test "setRemoteDescription: set offer - do not reject bundle only m-lines" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const offer =
        \\v=0
        \\o=- 1000 1779396395 IN IP4 0.0.0.0
        \\s=-
        \\t=0 0
        \\a=group:BUNDLE 0
        \\a=ice-options:ice2 
        \\a=fingerprint:sha-256 A4:14:A3:5D:02:35:5B:E0:C6:E0:EF:7D:D9:63:3F:30:D4:FD:43:76:50:A8:25:4A:96:25:F1:8A:0A:DC:F4:26
        \\m=video 9 UDP/TLS/RTP/SAVPF 96
        \\c=IN IP4 0.0.0.0
        \\a=rtpmap:96 VP8/90000
        \\a=fmtp:96 max-fs=12288;max-fr=60
        \\a=setup:actpass
        \\a=sendrecv
        \\a=mid:0
        \\a=rtcp-mux
        \\a=ice-ufrag:elsfVzJM
        \\a=ice-pwd:/KLNLMQnQm5TWswZ9MAnalyn
        \\m=video 0 UDP/TLS/RTP/SAVPF 96
        \\c=IN IP4 0.0.0.0
        \\a=bundle-only
        \\a=rtpmap:96 VP8/90000
        \\a=fmtp:96 max-fs=12288;max-fr=60
        \\a=setup:actpass
        \\a=sendrecv
        \\a=mid:1
        \\a=rtcp-mux
        \\
    ;

    try pc.setRemoteDescription(.{ .type = .offer, .sdp = offer });

    const event = try pc.poll();
    try std.testing.expectEqual(.signaling_state, std.meta.activeTag(event));
    try std.testing.expectEqual(.have_remote_offer, event.signaling_state);

    try std.testing.expectEqual(2, pc.getTransceivers().len);
    for (pc.getTransceivers()) |tr| {
        try std.testing.expectEqual(.video, tr.kind);
        try std.testing.expect(!tr.isStopped());
    }
}

test "setRemoteDescription: invalid state" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    try testing.expectError(error.NotImplemented, pc.setRemoteDescription(.{ .type = .pranswer, .sdp = "" }));
    try testing.expectError(error.NotImplemented, pc.setRemoteDescription(.{ .type = .rollback, .sdp = "" }));
    try testing.expectError(error.InvalidState, pc.setRemoteDescription(.{ .type = .answer, .sdp = "" }));

    var sdp = (try pc.createOffer()).sdp;
    try pc.setRemoteDescription(.{ .type = .offer, .sdp = sdp });
    try testing.expectError(error.InvalidState, pc.setRemoteDescription(.{ .type = .answer, .sdp = sdp }));

    const answer = try pc.createAnswer();
    try pc.setLocalDescription(answer);

    sdp = (try pc.createOffer()).sdp;
    try pc.setLocalDescription(.{ .type = .offer, .sdp = sdp });
    try testing.expectError(error.InvalidState, pc.setRemoteDescription(.{ .type = .offer, .sdp = sdp }));
}

test "addTrack" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const track: webrtc.MediaStreamTrack = .init(testing.io, .video);

    _ = try pc.addTrack(track, null);
    try std.testing.expectEqual(1, pc.transceivers.items.len);

    const tr = try pc.addTransceiverFromKind(.video, .{ .direction = .recvonly });
    try std.testing.expect(tr.sender.track == null);

    const sender = try pc.addTrack(.initWithId("track2", .video), null);
    try std.testing.expectEqual(sender, &tr.sender);
    try std.testing.expectEqual(2, pc.transceivers.items.len);
    try std.testing.expect(tr.sender.track != null);
    try std.testing.expectEqualStrings("track2", tr.sender.track.?.getId());
}

test "removeTrack" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const sender = try pc.addTrack(.initWithId("track1", .video), null);
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

        const tr = try pc.addTransceiverFromTrack(track, .{
            .direction = .sendrecv,
            .stream_id = "stream-1",
        });
        try std.testing.expectEqual(1, pc.transceivers.items.len);
        try std.testing.expectEqual(.sendrecv, tr.direction);
        try std.testing.expectEqualStrings(&track.id, &tr.sender.track.?.id);
        try std.testing.expect(tr.sender.ssrc != 0);

        const sender_track = tr.sender.track.?;
        try std.testing.expectEqualStrings("stream-1", sender_track.stream_id.?);

        const tr2 = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
        try std.testing.expectEqual(2, pc.transceivers.items.len);
        try std.testing.expectEqual(.recvonly, tr2.direction);
        try std.testing.expect(tr2.sender.track == null);
        try std.testing.expect(tr2.sender.ssrc != 0);

        try std.testing.expect(tr.sender.ssrc != tr2.sender.ssrc);
    }

    {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 5 });
        var pc = try PeerConnection.init(testing.io, failing_alloc.allocator(), .{});
        defer pc.deinit();

        try std.testing.expectError(error.OutOfMemory, pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly }));
    }
}

test "stopTransceiver" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const tr = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
    try std.testing.expect(!tr.isStopped());

    tr.stop();
    try std.testing.expect(tr.isStopped());
}

test "createOffer: empty offer" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.type);

    const sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    try testing.expectEqual(0, sdp_session.getMedias().len);
}

test "createOffer: m-lines created for each transceiver" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    _ = try pc.addTrack(.initWithId("video", .video), null);
    _ = try pc.addTrack(.initWithId("audio", .audio), null);
    _ = try pc.addTrack(.initWithId("video", .video), null);

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.type);

    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    try testing.expectEqual(3, sdp_session.getMedias().len);
    const transceivers = pc.getTransceivers();
    const medias = sdp_session.getMedias();
    for (transceivers, medias, 0..) |tr, media, idx| {
        try testing.expectEqual(media.kind, tr.kind);
        try testing.expectEqual(idx, tr.sdp_mline_index.?);
        try testing.expect(media.mid != 0);
    }
}

test "createOffer: stopped non-associted transceiver is ignored" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    const tr = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
    tr.stop();

    _ = try pc.addTrack(.initWithId("video", .video), null);

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.type);

    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    try testing.expectEqual(1, sdp_session.getMedias().len);
}

test "createOffer: multiple offers" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    _ = try pc.addTrack(.initWithId("video", .video), null);
    _ = try pc.addTrack(.initWithId("audio", .audio), null);

    var offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
    pc.getTransceivers()[1].stop();

    offer = try pc.createOffer();
    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    try testing.expectEqual(2, sdp_session.getMedias().len);
    try testing.expect(sdp_session.getMedias()[1].port == 0);
    const old_mid = sdp_session.getMedias()[1].mid;

    try pc.setLocalDescription(offer);
    _ = try pc.addTrack(.initWithId("video2", .video), null);

    offer = try pc.createOffer();
    sdp_session.deinit(testing.allocator);
    sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    // Test media recycling
    try testing.expectEqual(2, sdp_session.getMedias().len);
    try testing.expect(sdp_session.getMedias()[1].port != 0);
    try testing.expect(old_mid != sdp_session.getMedias()[1].mid);
}

test "createAnswer: answer to offer" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    var pc2 = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc2.deinit();

    _ = try pc.addTrack(.initWithId("video", .video), null);
    _ = try pc.addTrack(.initWithId("audio", .audio), null);

    const offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
    try pc2.setRemoteDescription(offer);

    const answer = try pc2.createAnswer();
    try testing.expectEqual(.answer, answer.type);

    var sdp_session = try SDPSession.parse(testing.allocator, answer.sdp);
    defer sdp_session.deinit(testing.allocator);

    try testing.expectEqual(2, sdp_session.getMedias().len);
    try testing.expect(sdp_session.getMedias()[0].port != 0);
    try testing.expect(sdp_session.getMedias()[1].port != 0);
}

test "createAnswer: reject media in offer" {
    var pc = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc.deinit();

    var pc2 = try PeerConnection.init(testing.io, testing.allocator, .{});
    defer pc2.deinit();

    _ = try pc.addTrack(.initWithId("video", .video), null);
    _ = try pc.addTrack(.initWithId("audio", .audio), null);

    const offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
    try pc2.setRemoteDescription(offer);

    pc2.getTransceivers()[1].stop();

    const answer = try pc2.createAnswer();
    try testing.expectEqual(.answer, answer.type);

    var sdp_session = try SDPSession.parse(testing.allocator, answer.sdp);
    defer sdp_session.deinit(testing.allocator);

    try testing.expectEqual(2, sdp_session.getMedias().len);
    try testing.expect(sdp_session.getMedias()[0].port != 0);
    try testing.expect(sdp_session.getMedias()[1].port == 0);
}

test "negotiation between peers" {
    var pc1: PeerConnection = try .init(io, allocator, .{});
    defer pc1.deinit();

    var pc2: PeerConnection = try .init(io, allocator, .{});
    defer pc2.deinit();

    const sender1 = try pc1.addTrack(.initWithId("track-1", .video), "stream-1");
    const sender2 = try pc1.addTrack(.init(testing.io, .video), "stream-2");

    try negotiate(&pc1, &pc2);

    const transceivers = pc2.getTransceivers();
    try testing.expectEqual(2, transceivers.len);
    var track = transceivers[0].receiver.track;
    try testing.expectEqualStrings(sender1.track.?.getId(), track.getId());
    try testing.expectEqualStrings("stream-1", track.stream_id.?);

    track = transceivers[1].receiver.track;
    try testing.expectEqualStrings(sender2.track.?.getId(), track.getId());
    try testing.expectEqualStrings("stream-2", track.stream_id.?);
}

test "negotiation between peers: add/remove tracks" {
    var pc1: PeerConnection = try .init(io, allocator, .{});
    defer pc1.deinit();

    var pc2: PeerConnection = try .init(io, allocator, .{});
    defer pc2.deinit();

    var pc1_collector: EventCollector = .init();
    var pc2_collector: EventCollector = .init();
    defer pc1_collector.deinit();
    defer pc2_collector.deinit();

    try pc1_collector.collect(&pc1);
    try pc2_collector.collect(&pc2);

    const track1: webrtc.MediaStreamTrack = .init(testing.io, .video);

    _ = try pc1.addTrack(track1, null);
    _ = try pc1.addTrack(.init(testing.io, .video), null);

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
    var event = pc2_collector.popEvent(.track_event_init, .fromMilliseconds(50));
    try testing.expect(event != null);
    event = pc2_collector.popEvent(.track_event_init, .fromMilliseconds(50));
    try testing.expect(event != null);
    event = pc2_collector.popEvent(.track_event_init, .fromMilliseconds(50));
    try testing.expect(event == null);

    for (0..10) |_| {
        const screen1 = try pc1.addTrack(.initWithId("screenshare", .video), null);
        const screen2 = try pc2.addTrack(.initWithId("screenshare", .video), null);
        try negotiate(&pc1, &pc2);

        try testing.expectEqual(3, pc1.getTransceivers().len);
        try testing.expectEqual(3, pc2.getTransceivers().len);

        event = pc1_collector.popEvent(.track_event_init, .fromMilliseconds(50));
        try testing.expect(event != null);
        try testing.expectEqualStrings(&track1.id, &event.?.track_event_init.track.id);

        try pc1.removeTrack(screen1);
        try pc2.removeTrack(screen2);
        try negotiate(&pc1, &pc2);
    }

    event = pc1_collector.popEvent(.track_event_init, .fromMilliseconds(50));
    try testing.expect(event == null);

    event = pc2_collector.popEvent(.track_event_init, .fromMilliseconds(50));
    try testing.expect(event != null);

    event = pc2_collector.popEvent(.track_event_init, .fromMilliseconds(50));
    try testing.expect(event == null);
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
    group: std.Io.Group,
    events: std.ArrayList(PeerConnection.Event),
    mutex: std.Io.Mutex,

    fn init() EventCollector {
        return .{
            .group = .init,
            .events = .empty,
            .mutex = .init,
        };
    }

    fn deinit(collector: *EventCollector) void {
        collector.group.cancel(io);
        collector.events.deinit(allocator);
    }

    fn collect(collector: *EventCollector, pc: *PeerConnection) !void {
        try collector.group.concurrent(io, collectEvents, .{ collector, pc });
    }

    fn collectEvents(collector: *EventCollector, pc: *PeerConnection) !void {
        while (pc.poll()) |event| {
            try collector.mutex.lock(io);
            defer collector.mutex.unlock(io);
            collector.events.append(allocator, event) catch return;
        } else |_| {}
    }

    fn popEvent(collector: *EventCollector, event_type: PCEvent, duration: std.Io.Duration) ?PeerConnection.Event {
        const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
        while (true) {
            {
                collector.mutex.lockUncancelable(io);
                defer collector.mutex.unlock(io);
                for (collector.events.items, 0..) |event, idx| if (std.meta.activeTag(event) == event_type) {
                    return collector.events.orderedRemove(idx);
                };
            }

            const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - start;
            if (elapsed >= duration.nanoseconds) return null;
            io.sleep(.fromMilliseconds(5), .awake) catch return null;
        }
    }
};
