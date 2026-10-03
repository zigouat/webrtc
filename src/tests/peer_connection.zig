const std = @import("std");
const PeerConnection = @import("../peer_connection2.zig");
const webrtc = @import("../webrtc.zig");
const SDPSession = @import("../sdp_session.zig");

const testing = std.testing;

const io = testing.io;
const allocator = testing.allocator;
const PCEnum = @typeInfo(PeerConnection.Event).@"union".tag_type.?;

const Connection = struct {
    pc: PeerConnection,
    media_engine: *webrtc.MediaEngine,

    const Config = struct {
        enable_rtx: bool = false,
    };

    fn init(config: Config) !Connection {
        const media_engine = try allocator.create(webrtc.MediaEngine);
        errdefer allocator.destroy(media_engine);

        media_engine.* = try testMediaEngine(config.enable_rtx);
        try media_engine.registerDefaultCodecs(allocator);
        errdefer media_engine.deinit(allocator);

        const pc = try PeerConnection.init(io, allocator, .{
            .media_engine = media_engine,
            .random = prng.random(),
        });

        return .{ .pc = pc, .media_engine = media_engine };
    }

    fn deinit(conn: *Connection) void {
        conn.pc.deinit();
        conn.media_engine.deinit(allocator);
        allocator.destroy(conn.media_engine);
    }

    fn popEvent(conn: *Connection, event_type: PCEnum) ?webrtc.PeerConnection2.Event {
        return blk: {
            while (conn.pc.pollEvent()) |event| if (std.meta.activeTag(event) == event_type) {
                break :blk event;
            };

            break :blk null;
        };
    }

    fn expectEvent(conn: *Connection, comptime event_type: PCEnum, expected: @FieldType(PeerConnection.Event, @tagName(event_type))) !void {
        const event = conn.popEvent(event_type);
        try std.testing.expect(event != null);
        try std.testing.expectEqual(event_type, std.meta.activeTag(event.?));
        try std.testing.expectEqual(expected, @field(event.?, @tagName(event_type)));
    }

    fn expectNoEvent(conn: *Connection, event_type: PCEnum) !void {
        const event = conn.popEvent(event_type);
        try std.testing.expect(event == null);
    }
};

fn testMediaEngine(enable_rtx: bool) !webrtc.MediaEngine {
    var engine: webrtc.MediaEngine = .init(.{ .enable_rtx = enable_rtx });
    try engine.registerDefaultCodecs(testing.allocator);
    return engine;
}

var prng = std.Random.DefaultPrng.init(0xDEADBEEF);

test "PeerConnection.init" {
    var media_engine = try testMediaEngine(false);
    defer media_engine.deinit(testing.allocator);

    var pc = try PeerConnection.init(testing.io, testing.allocator, .{
        .media_engine = &media_engine,
        .random = prng.random(),
    });
    defer pc.deinit();
}

test "PeerConnection.addTransceiverFromKind: no leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var media_engine = try testMediaEngine(false);
            defer media_engine.deinit(testing.allocator);

            var pc = try PeerConnection.init(io, alloc, .{
                .media_engine = &media_engine,
                .random = prng.random(),
            });
            defer pc.deinit();
            _ = try pc.addTransceiverFromKind(.video, .{ .direction = .sendrecv, .stream_id = "stream" });
        }
    }.run, .{});
}

test "PeerConnection.setLocalDescription: set offer" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const offer = try pc.createOffer();
    try pc.setLocalDescription(offer);

    try conn.expectEvent(.signaling_state, .have_local_offer);
}

test "PeerConnection.setLocalDescription: set offer multiple times" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    var offer = try pc.createOffer();
    try pc.setLocalDescription(offer);

    _ = try pc.addTrack(.initWithId("video-track", .video), null);
    _ = try pc.addTrack(.initWithId("audio-track", .audio), null);

    offer = try pc.createOffer();
    try pc.setLocalDescription(offer);
}

test "PeerConnection.setLocalDescription: invalid state" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

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

test "PeerConnection.setRemoteDescription: set offer" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

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
    try conn.expectEvent(.signaling_state, .have_remote_offer);

    for (0..5) |_| try pc.setRemoteDescription(.{ .type = .offer, .sdp = offer });
    try conn.expectNoEvent(.signaling_state);
}

test "PeerConnection.setRemoteDescription: set offer - do not reject bundle only m-lines" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const offer =
        \\v=0
        \\o=- 1000 1779396395 IN IP4 0.0.0.0
        \\s=-
        \\t=0 0
        \\a=group:BUNDLE 0 1
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

    try conn.expectEvent(.signaling_state, .have_remote_offer);

    try std.testing.expectEqual(2, pc.getTransceivers().len);
    for (pc.getTransceivers()) |tr| {
        try std.testing.expectEqual(.video, tr.kind);
        try std.testing.expect(!tr.isStopped());
    }
}

test "PeerConnection.setRemoteDescription: set offer - data channel media does not create a transceiver" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const offer =
        \\v=0
        \\o=- 1000 1779396395 IN IP4 0.0.0.0
        \\s=-
        \\t=0 0
        \\a=group:BUNDLE 0 1
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
        \\m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        \\c=IN IP4 0.0.0.0
        \\a=setup:actpass
        \\a=mid:1
        \\a=sctp-port:5000
        \\
    ;

    try pc.setRemoteDescription(.{ .type = .offer, .sdp = offer });

    try conn.expectEvent(.signaling_state, .have_remote_offer);

    try std.testing.expectEqual(1, pc.getTransceivers().len);
    try std.testing.expectEqual(.video, pc.getTransceivers()[0].kind);
}

test "PeerConnection.setRemoteDescription: invalid state" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

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

test "PeerConnection.addTrack" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const track: webrtc.MediaStreamTrack = .init(.video, prng.random());

    _ = try pc.addTrack(track, null);
    try std.testing.expectEqual(1, pc.transceivers.items.len);

    const trasceiver_id = try pc.addTransceiverFromKind(.video, .{ .direction = .recvonly });
    const tr = &pc.getTransceivers()[trasceiver_id];
    try std.testing.expect(tr.sender.track == null);

    const sender_id = try pc.addTrack(.initWithId("track2", .video), null);
    try std.testing.expectEqual(sender_id, trasceiver_id);
    try std.testing.expectEqual(2, pc.transceivers.items.len);
    try std.testing.expect(tr.sender.track != null);
    try std.testing.expectEqualStrings("track2", tr.sender.track.?.getId());
}

test "PeerConnection.removeTrack" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const sender_id = try pc.addTrack(.initWithId("track1", .video), null);
    try pc.removeTrack(sender_id);

    const tr = &pc.getTransceivers()[sender_id];
    try testing.expect(tr.sender.track == null);
    try testing.expectEqual(.recvonly, tr.direction);
}

test "PeerConnection.addTransceiver" {
    {
        var conn = try Connection.init(.{});
        var pc = &conn.pc;
        defer conn.deinit();

        const track: webrtc.MediaStreamTrack = .initWithId("track1", .video);

        const transceiver_id = try pc.addTransceiverFromTrack(track, .{
            .direction = .sendrecv,
            .stream_id = "stream-1",
        });
        const tr = &pc.getTransceivers()[transceiver_id];
        try std.testing.expectEqual(1, pc.transceivers.items.len);
        try std.testing.expectEqual(.sendrecv, tr.direction);
        try std.testing.expectEqualStrings(&track.id, &tr.sender.track.?.id);
        try std.testing.expect(tr.sender.ssrc != 0);

        const sender_track = tr.sender.track.?;
        try std.testing.expectEqualStrings("stream-1", sender_track.stream_id.?);

        const tr2_id = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
        const tr2 = &pc.getTransceivers()[tr2_id];
        try std.testing.expectEqual(2, pc.transceivers.items.len);
        try std.testing.expectEqual(.recvonly, tr2.direction);
        try std.testing.expect(tr2.sender.track == null);
        try std.testing.expect(tr2.sender.ssrc != 0);

        try std.testing.expect(tr.sender.ssrc != tr2.sender.ssrc);
    }

    {
        var media_engine = try testMediaEngine(false);
        defer media_engine.deinit(testing.allocator);

        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 6 });
        var pc = try PeerConnection.init(testing.io, failing_alloc.allocator(), .{
            .media_engine = &media_engine,
            .random = prng.random(),
        });
        defer pc.deinit();

        try std.testing.expectError(error.OutOfMemory, pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly }));
    }
}

test "PeerConnection.stopTransceiver" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const tr_id = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
    const tr = &pc.getTransceivers()[tr_id];
    try std.testing.expect(!tr.isStopped());

    tr.stop();
    try std.testing.expect(tr.isStopped());
}

test "PeerConnection.createOffer: empty offer" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.type);

    const sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    try testing.expectEqual(0, sdp_session.getMedias().len);
}

test "PeerConnection.createOffer: m-lines created for each transceiver" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

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
        try testing.expectEqual(media.getKind(), tr.kind);
        try testing.expectEqual(idx, tr.sdp_mline_index.?);
        try testing.expect(media.mid != 0);
    }
}

test "PeerConnection.createOffer: enable_rtx synthesizes rtx codecs for video only" {
    var conn = try Connection.init(.{ .enable_rtx = true });
    var pc = &conn.pc;
    defer conn.deinit();

    _ = try pc.addTrack(.initWithId("video", .video), null);
    _ = try pc.addTrack(.initWithId("audio", .audio), null);

    const offer = try pc.createOffer();
    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    const medias = sdp_session.getMedias();
    for (medias) |media| {
        var saw_rtx = false;
        for (media.rtp_codec_parameters) |codec| {
            if (codec.isRtx()) {
                saw_rtx = true;
            } else if (media.kind == .video) {
                try testing.expect(codec.rtp_codec.rtcp_feedbacks.nack);
            }
        }
        try testing.expectEqual(media.kind == .video, saw_rtx);
    }
}

test "PeerConnection.createOffer: enable_rtx defaults to false, never emits rtx codecs" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    _ = try pc.addTrack(.initWithId("video", .video), null);

    const offer = try pc.createOffer();
    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    for (sdp_session.getMedias()) |media| {
        for (media.rtp_codec_parameters) |codec| try testing.expect(!codec.isRtx());
    }
}

test "PeerConnection.createOffer: stopped non-associted transceiver is ignored" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    const tr_id = try pc.addTransceiverFromKind(.audio, .{ .direction = .recvonly });
    const tr = &pc.getTransceivers()[tr_id];
    tr.stop();

    _ = try pc.addTrack(.initWithId("video", .video), null);

    const offer = try pc.createOffer();
    try testing.expectEqual(.offer, offer.type);

    var sdp_session = try SDPSession.parse(testing.allocator, offer.sdp);
    defer sdp_session.deinit(testing.allocator);

    try testing.expectEqual(1, sdp_session.getMedias().len);
}

test "PeerConnection.createOffer: multiple offers" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

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

test "PeerConnection.createAnswer: answer to offer" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    var conn2 = try Connection.init(.{});
    var pc2 = &conn2.pc;
    defer conn2.deinit();

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

test "PeerConnection.createAnswer: reject media in offer" {
    var conn = try Connection.init(.{});
    var pc = &conn.pc;
    defer conn.deinit();

    var conn2 = try Connection.init(.{});
    var pc2 = &conn2.pc;
    defer conn2.deinit();

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

test "PeerConnection.negotiation between peers" {
    var conn1 = try Connection.init(.{});
    var pc1 = &conn1.pc;
    defer conn1.deinit();

    var conn2 = try Connection.init(.{});
    var pc2 = &conn2.pc;
    defer conn2.deinit();

    const sender1_id = try pc1.addTrack(.initWithId("track-1", .video), "stream-1");
    const sender2_id = try pc1.addTrack(.init(.video, prng.random()), "stream-2");

    const sender1 = &pc1.getTransceivers()[sender1_id].sender;
    const sender2 = &pc1.getTransceivers()[sender2_id].sender;

    try negotiate(pc1, pc2);

    const transceivers = pc2.getTransceivers();
    try testing.expectEqual(2, transceivers.len);
    var track = transceivers[0].receiver.track;
    try testing.expectEqualStrings(sender1.track.?.getId(), track.getId());
    try testing.expectEqualStrings("stream-1", track.stream_id.?);

    track = transceivers[1].receiver.track;
    try testing.expectEqualStrings(sender2.track.?.getId(), track.getId());
    try testing.expectEqualStrings("stream-2", track.stream_id.?);

    try testing.expect(pc1.demuxer.mid_id != null);
    try testing.expect(pc2.demuxer.mid_id != null);
    try testing.expect(sender1.header_extensions.mid != 0);
    for (transceivers) |tr| try testing.expect(tr.sender.header_extensions.mid != 0);
}

test "PeerConnection.negotiation between peers: add/remove tracks" {
    var conn1 = try Connection.init(.{});
    defer conn1.deinit();

    var conn2 = try Connection.init(.{});
    defer conn2.deinit();

    const pc1 = &conn1.pc;
    const pc2 = &conn2.pc;

    const track1: webrtc.MediaStreamTrack = .init(.video, prng.random());

    _ = try pc1.addTrack(track1, null);
    _ = try pc1.addTrack(.init(.video, prng.random()), null);

    try negotiate(pc1, pc2);

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
    var event = conn2.popEvent(.track);
    try testing.expect(event != null);

    event = conn2.popEvent(.track);
    try testing.expect(event != null);

    event = conn2.popEvent(.track);
    try testing.expect(event == null);

    for (0..10) |_| {
        const screen1 = try pc1.addTrack(.initWithId("screenshare", .video), null);
        const screen2 = try pc2.addTrack(.initWithId("screenshare", .video), null);
        try negotiate(pc1, pc2);

        try testing.expectEqual(3, pc1.getTransceivers().len);
        try testing.expectEqual(3, pc2.getTransceivers().len);

        event = conn1.popEvent(.track);
        try testing.expect(event != null);
        try testing.expectEqualStrings(&track1.id, &event.?.track.track.id);

        try pc1.removeTrack(screen1);
        try pc2.removeTrack(screen2);
        try negotiate(pc1, pc2);
    }

    event = conn1.popEvent(.track);
    try testing.expect(event == null);

    event = conn2.popEvent(.track);
    try testing.expect(event != null);

    event = conn2.popEvent(.track);
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
