const std = @import("std");
const webrtc = @import("../webrtc.zig");

const testing = std.testing;

const SDPSession = @import("../sdp_session.zig");
const Mid = @import("../mid.zig");

const head =
    \\v=0
    \\o=- 6376631644514588552 1781629529 IN IP4 0.0.0.0
    \\s=-
    \\t=0 0
    \\
;

const offer_txt =
    head ++
    \\a=msid-semantic:WMS *
    \\a=fingerprint:sha-256 0E:76:E3:F8:ED:5F:C4:BD:F7:3D:04:6A:E8:D3:C6:A1:AF:93:73:30:26:84:AC:3F:49:0D:01:6F:E9:09:91:D0
    \\a=extmap-allow-mixed
    \\a=group:BUNDLE 0 1
    \\m=audio 9 UDP/TLS/RTP/SAVPF 111 9 0 8
    \\c=IN IP4 0.0.0.0
    \\a=setup:actpass
    \\a=mid:0
    \\a=ice-ufrag:YBvMzurJIEpKGlbQ
    \\a=ice-pwd:xWVHffXavbkalUfEXPyeKkyMRnyyYggx
    \\a=rtcp-mux
    \\a=rtcp-rsize
    \\a=rtpmap:111 opus/48000/2
    \\a=fmtp:111 minptime=10;useinbandfec=1
    \\a=rtcp-fb:111 transport-cc
    \\a=rtpmap:9 G722/8000
    \\a=rtcp-fb:9 transport-cc
    \\a=rtpmap:0 PCMU/8000
    \\a=rtcp-fb:0 transport-cc
    \\a=rtpmap:8 PCMA/8000
    \\a=rtcp-fb:8 transport-cc
    \\a=extmap:4 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
    \\a=ssrc:3427430813 cname:dummy
    \\a=ssrc:3427430813 msid:dummy audio
    \\a=ssrc:3427430813 mslabel:dummy
    \\a=ssrc:3427430813 label:audio
    \\a=msid:dummy audio
    \\a=sendrecv
    \\a=candidate:1915787389 1 udp 2130706431 192.168.8.157 52225 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:1915787389 2 udp 2130706431 192.168.8.157 52225 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:574494503 1 udp 2130706431 192.168.122.1 33845 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:574494503 2 udp 2130706431 192.168.122.1 33845 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:233762139 1 udp 2130706431 172.17.0.1 40560 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:233762139 2 udp 2130706431 172.17.0.1 40560 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:3528925834 1 udp 2130706431 172.18.0.1 50348 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:3528925834 2 udp 2130706431 172.18.0.1 50348 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:1906588769 1 udp 2130706431 10.5.0.2 59187 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:1906588769 2 udp 2130706431 10.5.0.2 59187 typ host ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:1054609236 1 udp 1694498815 193.43.70.26 64049 typ srflx raddr 0.0.0.0 rport 42506 ufrag YBvMzurJIEpKGlbQ
    \\a=candidate:1054609236 2 udp 1694498815 193.43.70.26 64049 typ srflx raddr 0.0.0.0 rport 42506 ufrag YBvMzurJIEpKGlbQ
    \\a=end-of-candidates
    \\m=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103 104 105 106 107 108 109 127 125 39 40 116 117 45 46 98 99 100 101 112 113
    \\c=IN IP4 0.0.0.0
    \\a=setup:actpass
    \\a=mid:1
    \\a=ice-ufrag:YBvMzurJIEpKGlbQ
    \\a=ice-pwd:xWVHffXavbkalUfEXPyeKkyMRnyyYggx
    \\a=rtcp-mux
    \\a=rtcp-rsize
    \\a=rtpmap:96 VP8/90000
    \\a=rtcp-fb:96 goog-remb
    \\a=rtcp-fb:96 ccm fir
    \\a=rtcp-fb:96 nack
    \\a=rtcp-fb:96 nack pli
    \\a=rtcp-fb:96 transport-cc
    \\a=rtpmap:97 rtx/90000
    \\a=fmtp:97 apt=96
    \\a=rtcp-fb:97 nack
    \\a=rtcp-fb:97 nack pli
    \\a=rtcp-fb:97 transport-cc
    \\a=rtpmap:102 H264/90000
    \\a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f
    \\a=rtcp-fb:102 goog-remb
    \\a=rtcp-fb:102 ccm fir
    \\a=rtcp-fb:102 nack
    \\a=rtcp-fb:102 nack pli
    \\a=rtcp-fb:102 transport-cc
    \\a=rtpmap:103 rtx/90000
    \\a=fmtp:103 apt=102
    \\a=rtcp-fb:103 nack
    \\a=rtcp-fb:103 nack pli
    \\a=rtcp-fb:103 transport-cc
    \\a=rtpmap:104 H264/90000
    \\a=fmtp:104 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f
    \\a=rtcp-fb:104 goog-remb
    \\a=rtcp-fb:104 ccm fir
    \\a=rtcp-fb:104 nack
    \\a=rtcp-fb:104 nack pli
    \\a=rtcp-fb:104 transport-cc
    \\a=rtpmap:105 rtx/90000
    \\a=fmtp:105 apt=104
    \\a=rtcp-fb:105 nack
    \\a=rtcp-fb:105 nack pli
    \\a=rtcp-fb:105 transport-cc
    \\a=rtpmap:106 H264/90000
    \\a=fmtp:106 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
    \\a=rtcp-fb:106 goog-remb
    \\a=rtcp-fb:106 ccm fir
    \\a=rtcp-fb:106 nack
    \\a=rtcp-fb:106 nack pli
    \\a=rtcp-fb:106 transport-cc
    \\a=rtpmap:107 rtx/90000
    \\a=fmtp:107 apt=106
    \\a=rtcp-fb:107 nack
    \\a=rtcp-fb:107 nack pli
    \\a=rtcp-fb:107 transport-cc
    \\a=rtpmap:108 H264/90000
    \\a=fmtp:108 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e01f
    \\a=rtcp-fb:108 goog-remb
    \\a=rtcp-fb:108 ccm fir
    \\a=rtcp-fb:108 nack
    \\a=rtcp-fb:108 nack pli
    \\a=rtcp-fb:108 transport-cc
    \\a=rtpmap:109 rtx/90000
    \\a=fmtp:109 apt=108
    \\a=rtcp-fb:109 nack
    \\a=rtcp-fb:109 nack pli
    \\a=rtcp-fb:109 transport-cc
    \\a=rtpmap:127 H264/90000
    \\a=fmtp:127 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f
    \\a=rtcp-fb:127 goog-remb
    \\a=rtcp-fb:127 ccm fir
    \\a=rtcp-fb:127 nack
    \\a=rtcp-fb:127 nack pli
    \\a=rtcp-fb:127 transport-cc
    \\a=rtpmap:125 rtx/90000
    \\a=fmtp:125 apt=127
    \\a=rtcp-fb:125 nack
    \\a=rtcp-fb:125 nack pli
    \\a=rtcp-fb:125 transport-cc
    \\a=rtpmap:39 H264/90000
    \\a=fmtp:39 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=4d001f
    \\a=rtcp-fb:39 goog-remb
    \\a=rtcp-fb:39 ccm fir
    \\a=rtcp-fb:39 nack
    \\a=rtcp-fb:39 nack pli
    \\a=rtcp-fb:39 transport-cc
    \\a=rtpmap:40 rtx/90000
    \\a=fmtp:40 apt=39
    \\a=rtcp-fb:40 nack
    \\a=rtcp-fb:40 nack pli
    \\a=rtcp-fb:40 transport-cc
    \\a=rtpmap:116 H265/90000
    \\a=rtcp-fb:116 goog-remb
    \\a=rtcp-fb:116 ccm fir
    \\a=rtcp-fb:116 nack
    \\a=rtcp-fb:116 nack pli
    \\a=rtcp-fb:116 transport-cc
    \\a=rtpmap:117 rtx/90000
    \\a=fmtp:117 apt=116
    \\a=rtcp-fb:117 nack
    \\a=rtcp-fb:117 nack pli
    \\a=rtcp-fb:117 transport-cc
    \\a=rtpmap:45 AV1/90000
    \\a=rtcp-fb:45 goog-remb
    \\a=rtcp-fb:45 ccm fir
    \\a=rtcp-fb:45 nack
    \\a=rtcp-fb:45 nack pli
    \\a=rtcp-fb:45 transport-cc
    \\a=rtpmap:46 rtx/90000
    \\a=fmtp:46 apt=45
    \\a=rtcp-fb:46 nack
    \\a=rtcp-fb:46 nack pli
    \\a=rtcp-fb:46 transport-cc
    \\a=rtpmap:98 VP9/90000
    \\a=fmtp:98 profile-id=0
    \\a=rtcp-fb:98 goog-remb
    \\a=rtcp-fb:98 ccm fir
    \\a=rtcp-fb:98 nack
    \\a=rtcp-fb:98 nack pli
    \\a=rtcp-fb:98 transport-cc
    \\a=rtpmap:99 rtx/90000
    \\a=fmtp:99 apt=98
    \\a=rtcp-fb:99 nack
    \\a=rtcp-fb:99 nack pli
    \\a=rtcp-fb:99 transport-cc
    \\a=rtpmap:100 VP9/90000
    \\a=fmtp:100 profile-id=2
    \\a=rtcp-fb:100 goog-remb
    \\a=rtcp-fb:100 ccm fir
    \\a=rtcp-fb:100 nack
    \\a=rtcp-fb:100 nack pli
    \\a=rtcp-fb:100 transport-cc
    \\a=rtpmap:101 rtx/90000
    \\a=fmtp:101 apt=100
    \\a=rtcp-fb:101 nack
    \\a=rtcp-fb:101 nack pli
    \\a=rtcp-fb:101 transport-cc
    \\a=rtpmap:112 H264/90000
    \\a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f
    \\a=rtcp-fb:112 goog-remb
    \\a=rtcp-fb:112 ccm fir
    \\a=rtcp-fb:112 nack
    \\a=rtcp-fb:112 nack pli
    \\a=rtcp-fb:112 transport-cc
    \\a=rtpmap:113 rtx/90000
    \\a=fmtp:113 apt=112
    \\a=rtcp-fb:113 nack
    \\a=rtcp-fb:113 nack pli
    \\a=rtcp-fb:113 transport-cc
    \\a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id
    \\a=extmap:4 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
    \\a=extmap:1 urn:ietf:params:rtp-hdrext:sdes:mid
    \\a=extmap:2 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
    \\a=ssrc-group:FID 3213490500 428397658
    \\a=ssrc:3213490500 cname:dummy
    \\a=ssrc:3213490500 msid:dummy video
    \\a=ssrc:3213490500 mslabel:dummy
    \\a=ssrc:3213490500 label:video
    \\a=ssrc:428397658 cname:dummy
    \\a=ssrc:428397658 msid:dummy video
    \\a=ssrc:428397658 mslabel:dummy
    \\a=ssrc:428397658 label:video
    \\a=msid:dummy video
    \\a=sendrecv
    \\
    ;

test "parse: sdp offer" {
    var session: SDPSession = try .parse(testing.allocator, offer_txt);
    defer session.deinit(testing.allocator);

    const expected_fingerprint = [_]u8{
        0x0E, 0x76, 0xE3, 0xF8, 0xED, 0x5F, 0xC4, 0xBD, 0xF7,
        0x3D, 0x04, 0x6A, 0xE8, 0xD3, 0xC6, 0xA1, 0xAF, 0x93,
        0x73, 0x30, 0x26, 0x84, 0xAC, 0x3F, 0x49, 0x0D, 0x01,
        0x6F, 0xE9, 0x09, 0x91, 0xD0,
    };

    try testing.expectEqualSlices(u8, &expected_fingerprint, &session.fingerprint);
    try testing.expect(!session.ice_lite);
    try testing.expectEqual(2, session.getMedias().len);

    const audio_media = session.getMedias()[0];
    try testing.expectEqual(.audio, audio_media.kind);
    try testing.expectEqual(9, audio_media.port);
    try testing.expectEqual(0x30, audio_media.mid);
    try testing.expectEqual(.actpass, audio_media.setup);
    try testing.expectEqual(.sendrecv, audio_media.direction);
    try testing.expectEqualStrings("YBvMzurJIEpKGlbQ", audio_media.ice_ufrag);
    try testing.expectEqualStrings("xWVHffXavbkalUfEXPyeKkyMRnyyYggx", audio_media.ice_pwd);
    try testing.expect(audio_media.rtcp_mux);
    try testing.expect(audio_media.rtcp_rsize);

    try testing.expectEqual(12, audio_media.candidates.len);
    try testing.expect(audio_media.end_of_candidates);

    try testing.expect(audio_media.track_id != null);
    try testing.expectEqualStrings("audio", audio_media.track_id.?);
    try testing.expect(audio_media.msid != null);
    try testing.expectEqualStrings("dummy", audio_media.msid.?.id);

    try testing.expect(audio_media.ssrc != null);
    try testing.expectEqual(3427430813, audio_media.ssrc.?);
    try testing.expectEqual(null, audio_media.rtx_ssrc);

    const audio_codecs = audio_media.rtp_codec_parameters;
    try testing.expectEqual(4, audio_codecs.len);

    const expected_audio_codecs = [_]webrtc.RtpCodecParameters{
        .{
            .payload_type = 111,
            .mime_type = webrtc.MimeType.Opus,
            .clock_rate = 48000,
            .channels = 2,
            .fmtp_params = .{ .unknown = "minptime=10;useinbandfec=1" },
        },
        .{ .payload_type = 9, .mime_type = webrtc.MimeType.G722, .clock_rate = 8000 },
        .{ .payload_type = 0, .mime_type = webrtc.MimeType.PCMU, .clock_rate = 8000 },
        .{ .payload_type = 8, .mime_type = webrtc.MimeType.PCMA, .clock_rate = 8000 },
    };

    for (&expected_audio_codecs, audio_codecs) |*expected, *codec| {
        try testing.expect(expected.eql(codec));
    }

    for (audio_codecs) |*codec| {
        try testing.expectEqual(webrtc.RtcpFeedbacks{
            .nack = false,
            .nack_pli = false,
            .transport_cc = true,
            .ccm_fir = false,
            .goog_remb = false,
            ._pad = 0,
        }, codec.rtcp_feedbacks);
    }

    try testing.expectEqual(1, audio_media.rtp_header_extensions.len);
    try testing.expectEqual(4, audio_media.rtp_header_extensions[0].id);
    try testing.expectEqualStrings(
        "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
        audio_media.rtp_header_extensions[0].uri,
    );

    const video_media = session.getMedias()[1];
    try testing.expectEqual(.video, video_media.kind);
    try testing.expectEqual(9, video_media.port);
    try testing.expectEqual(0x31, video_media.mid);
    try testing.expectEqual(.actpass, audio_media.setup);
    try testing.expectEqual(.sendrecv, video_media.direction);
    try testing.expectEqualStrings("YBvMzurJIEpKGlbQ", video_media.ice_ufrag);
    try testing.expectEqualStrings("xWVHffXavbkalUfEXPyeKkyMRnyyYggx", video_media.ice_pwd);
    try testing.expect(video_media.rtcp_mux);
    try testing.expect(video_media.rtcp_rsize);

    try testing.expectEqual(0, video_media.candidates.len);
    try testing.expect(!video_media.end_of_candidates);

    try testing.expect(video_media.track_id != null);
    try testing.expectEqualStrings("video", video_media.track_id.?);
    try testing.expect(video_media.msid != null);
    try testing.expectEqualStrings("dummy", video_media.msid.?.id);

    try testing.expect(video_media.ssrc != null);
    try testing.expectEqual(3213490500, video_media.ssrc.?);
    try testing.expect(video_media.rtx_ssrc != null);
    try testing.expectEqual(428397658, video_media.rtx_ssrc.?);

    const video_codecs = video_media.rtp_codec_parameters;
    try testing.expectEqual(24, video_codecs.len);

    const expected_codecs = [_]webrtc.RtpCodecParameters{
        .{ .payload_type = 96, .mime_type = webrtc.MimeType.VP8, .clock_rate = 90000, .fmtp_params = null },
        rtx(97, 96),
        h264(104, true, 1, 0x42001f),
        rtx(103, 102),
        h264(104, true, 0, 0x42001f),
        rtx(105, 104),
        h264(108, true, 1, 0x42e01f),
        rtx(107, 106),
        h264(108, true, 0, 0x42e01f),
        rtx(109, 108),
        h264(127, true, 1, 0x4d001f),
        rtx(125, 127),
        h264(39, true, 0, 0x4d001f),
        rtx(40, 39),
        .{ .payload_type = 116, .mime_type = webrtc.MimeType.H265, .clock_rate = 90000, .fmtp_params = null },
        rtx(117, 116),
        .{ .payload_type = 45, .mime_type = webrtc.MimeType.AV1, .clock_rate = 90000, .fmtp_params = null },
        rtx(46, 45),
        .{ .payload_type = 98, .mime_type = webrtc.MimeType.VP9, .clock_rate = 90000, .fmtp_params = .{ .unknown = "profile-id=0" } },
        rtx(99, 98),
        .{ .payload_type = 100, .mime_type = webrtc.MimeType.VP9, .clock_rate = 90000, .fmtp_params = .{ .unknown = "profile-id=2" } },
        rtx(101, 100),
        h264(112, true, 1, 0x64001f),
        rtx(113, 112),
    };

    for (&expected_codecs, video_codecs) |*expected, *current| {
        try testing.expect(expected.eql(current));
    }

    for (video_codecs) |*codec| {
        const expected_fb: webrtc.RtcpFeedbacks = if (codec.isRtx())
            .{ .nack = true, .nack_pli = true, .transport_cc = true, .ccm_fir = false, .goog_remb = false, ._pad = 0 }
        else
            .{ .nack = true, .nack_pli = true, .transport_cc = true, .ccm_fir = true, .goog_remb = true, ._pad = 0 };
        try testing.expectEqual(expected_fb, codec.rtcp_feedbacks);
    }

    const hdr_extensions = video_media.rtp_header_extensions;
    try testing.expectEqual(4, hdr_extensions.len);
    try testing.expectEqual(3, hdr_extensions[0].id);
    try testing.expectEqualStrings("urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id", hdr_extensions[0].uri);
    try testing.expectEqual(4, hdr_extensions[1].id);
    try testing.expectEqualStrings("http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01", hdr_extensions[1].uri);
    try testing.expectEqual(1, hdr_extensions[2].id);
    try testing.expectEqualStrings("urn:ietf:params:rtp-hdrext:sdes:mid", hdr_extensions[2].uri);
    try testing.expectEqual(2, hdr_extensions[3].id);
    try testing.expectEqualStrings("urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id", hdr_extensions[3].uri);
}

test "parse: missing bundle group" {
    const sdp = head ++
        \\m=audio 9 UDP/TLS/RTP/SAVPF 111
        \\c=IN IP4 0.0.0.0
        \\a=rtpmap:111 opus/48000/2
        \\a=setup:actpass
        \\a=mid:0
        \\a=rtcp-mux
        \\
    ;

    try testing.expectError(
        error.MissingBundleGroup,
        SDPSession.parse(testing.allocator, sdp),
    );
}

test "parse: ice credentials mismatch" {
    const sdp = head ++
        \\a=group:BUNDLE 0 1
        \\m=video 9 UDP/TLS/RTP/SAVPF 96
        \\c=IN IP4 0.0.0.0
        \\a=rtpmap:96 H264/90000
        \\a=mid:0
        \\a=ice-ufrag:YBvMzurJIEpKGlbQ
        \\a=ice-pwd:xWVHffXavbkalUfEXPyeKkyMRnyyYggx
        \\a=rtcp-mux
        \\m=audio 9 UDP/TLS/RTP/SAVPF 100
        \\c=IN IP4 0.0.0.0
        \\a=rtpmap:100 Opus/90000
        \\a=mid:1
        \\a=ice-ufrag:YBvMzurJIEpKGlbQ
        \\a=ice-pwd:EXPyeKkyMRnyyYggxxWVHffXavbkalUf
        \\a=rtcp-mux
        \\
    ;
    try testing.expectError(
        error.MismatchedCredentials,
        SDPSession.parse(testing.allocator, sdp),
    );
}

test "parse: no leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var session: SDPSession = try .parse(alloc, offer_txt);
            defer session.deinit(testing.allocator);
        }
    }.run, .{});
}

test "write: media" {
    var media: SDPSession.SDPMedia = .empty;
    media.kind = .audio;
    media.port = 9;
    media.mid = try Mid.fromInt(0);
    media.direction = .sendrecv;
    media.ice_ufrag = "ufrag1";
    media.ice_pwd = "pwd1234567890123456789";
    media.setup = .actpass;
    media.rtcp_mux = true;
    media.track_id = "audio0";
    media.msid = .{ .id = "stream1" };
    media.ssrc = 12345;

    var codecs = [_]webrtc.RtpCodecParameters{.{
        .payload_type = 111,
        .mime_type = webrtc.MimeType.Opus,
        .clock_rate = 48000,
        .channels = 2,
        .fmtp_params = .{ .unknown = "minptime=10;useinbandfec=1" },
        .rtcp_feedbacks = .{
            .nack = false,
            .nack_pli = false,
            .transport_cc = true,
            .ccm_fir = false,
            .goog_remb = false,
            ._pad = 0,
        },
    }};
    media.rtp_codec_parameters = &codecs;

    var extensions = [_]webrtc.RtpHeaderExtensionParameter{.{ .id = 4, .uri = "http://example.com/ext" }};
    media.rtp_header_extensions = &extensions;

    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try media.write(&w);

    try testing.expectEqualStrings(
        "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "a=rtpmap:111 Opus/48000/2\r\n" ++
            "a=fmtp:111 minptime=10;useinbandfec=1\r\n" ++
            "a=rtcp-fb:111 transport-cc\r\n" ++
            "a=extmap:4 http://example.com/ext\r\n" ++
            "a=setup:actpass\r\n" ++
            "a=sendrecv\r\n" ++
            "a=mid:0\r\n" ++
            "a=rtcp-mux\r\n" ++
            "a=ice-ufrag:ufrag1\r\n" ++
            "a=ice-pwd:pwd1234567890123456789\r\n" ++
            "a=msid:stream1 audio0\r\n" ++
            "a=ssrc:12345 msid:stream1 audio0\r\n",
        w.buffered(),
    );
}

test "write: media with rtx ssrc emits ssrc-group:FID and a second ssrc line" {
    var media: SDPSession.SDPMedia = .empty;
    media.kind = .video;
    media.port = 9;
    media.mid = try Mid.fromInt(0);
    media.direction = .sendrecv;
    media.setup = .actpass;
    media.track_id = "video0";
    media.msid = .{ .id = "stream1" };
    media.ssrc = 12345;
    media.rtx_ssrc = 67890;

    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try media.write(&w);

    try testing.expectEqualStrings(
        "m=video 9 UDP/TLS/RTP/SAVPF\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "a=setup:actpass\r\n" ++
            "a=sendrecv\r\n" ++
            "a=mid:0\r\n" ++
            "a=msid:stream1 video0\r\n" ++
            "a=ssrc-group:FID 12345 67890\r\n" ++
            "a=ssrc:12345 msid:stream1 video0\r\n" ++
            "a=ssrc:67890 msid:stream1 video0\r\n",
        w.buffered(),
    );
}

test "write: rejected media" {
    var media: SDPSession.SDPMedia = .empty;
    media.kind = .video;
    media.bundle_only = true;
    media.mid = try Mid.fromInt(1);
    media.direction = .sendrecv;
    media.setup = .actpass;

    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try media.write(&w);

    try testing.expectEqualStrings(
        "m=video 0 UDP/TLS/RTP/SAVPF\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "a=bundle-only\r\n" ++
            "a=setup:actpass\r\n" ++
            "a=sendrecv\r\n" ++
            "a=mid:1\r\n",
        w.buffered(),
    );
}

test "write: session round-trip" {
    var session: SDPSession = try .parse(testing.allocator, offer_txt);
    defer session.deinit(testing.allocator);

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try session.write(&w.writer);

    var rewritten: SDPSession = try .parse(testing.allocator, w.writer.buffered());
    defer rewritten.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &session.fingerprint, &rewritten.fingerprint);
    try testing.expectEqual(session.getMedias().len, rewritten.getMedias().len);

    for (session.getMedias(), rewritten.getMedias()) |*orig, *new| {
        try testing.expectEqual(orig.kind, new.kind);
        try testing.expectEqual(orig.port, new.port);
        try testing.expectEqual(orig.mid, new.mid);
        try testing.expectEqual(orig.direction, new.direction);
        try testing.expectEqual(orig.setup, new.setup);
        try testing.expectEqualStrings(orig.ice_ufrag, new.ice_ufrag);
        try testing.expectEqualStrings(orig.ice_pwd, new.ice_pwd);
        try testing.expectEqual(orig.rtcp_mux, new.rtcp_mux);
        try testing.expectEqual(orig.ssrc, new.ssrc);
        try testing.expectEqual(orig.candidates.len, new.candidates.len);
        try testing.expectEqual(orig.end_of_candidates, new.end_of_candidates);

        try testing.expectEqual(orig.msid != null, new.msid != null);
        if (orig.msid) |om| if (new.msid) |nm| try testing.expectEqualStrings(om.id, nm.id);
        try testing.expectEqual(orig.track_id != null, new.track_id != null);
        if (orig.track_id) |ot| if (new.track_id) |nt| try testing.expectEqualStrings(ot, nt);

        try testing.expectEqual(orig.rtp_codec_parameters.len, new.rtp_codec_parameters.len);
        for (orig.rtp_codec_parameters, new.rtp_codec_parameters) |*o, *n| {
            try testing.expect(o.eql(n));
            try testing.expectEqual(o.rtcp_feedbacks, n.rtcp_feedbacks);
        }

        try testing.expectEqual(orig.rtp_header_extensions.len, new.rtp_header_extensions.len);
        for (orig.rtp_header_extensions, new.rtp_header_extensions) |o_ext, n_ext| {
            try testing.expectEqual(o_ext.id, n_ext.id);
            try testing.expectEqualStrings(o_ext.uri, n_ext.uri);
        }
    }
}

fn rtx(pt: u8, apt: u8) webrtc.RtpCodecParameters {
    return .{
        .payload_type = pt,
        .mime_type = webrtc.MimeType.Rtx,
        .clock_rate = 90000,
        .fmtp_params = .{ .rtx = .{ .apt = apt } },
    };
}

fn h264(pt: u8, level_asym: bool, pm: u8, profile: u24) webrtc.RtpCodecParameters {
    return .{
        .payload_type = pt,
        .mime_type = webrtc.MimeType.H264,
        .clock_rate = 90000,
        .fmtp_params = .{ .h264 = .{ .level_asymmetry_allowed = level_asym, .packetization_mode = pm, .profile_level_id = profile } },
    };
}
