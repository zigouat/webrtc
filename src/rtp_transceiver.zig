const std = @import("std");
const webrtc = @import("webrtc.zig");
const utils = @import("utils.zig");
const DtlsTransport = @import("dtls_transport.zig");
const SDPSession = @import("sdp_session.zig");
const RtpSender = @import("rtp_sender.zig");
const RtpReceiver = @import("rtp_receiver.zig");

const Io = std.Io;
const RtpTransceiver = @This();
const MediaStream = webrtc.MediaStream;
const MediaStreamTrack = webrtc.MediaStreamTrack;
const TrackKind = webrtc.TrackKind;

/// A struct describing the possible direction of transceivers.
pub const Direction = enum {
    /// Used to indicate send and receive capabilities.
    sendrecv,
    /// Used to indicate send-only capabilities.
    sendonly,
    /// Used to indicate receive-only capabilities.
    recvonly,
    /// Used to indicate that the transceiver is neither sending nor receiving media.
    inactive,

    /// Returns the reverse of the given direction.
    pub fn reverse(direction: Direction) Direction {
        return switch (direction) {
            .sendonly => .recvonly,
            .recvonly => .sendonly,
            .inactive, .sendrecv => |d| d,
        };
    }

    /// Returns the intersection of two directions.
    pub fn intersect(a: Direction, b: Direction) Direction {
        if (a == b) return a;
        if (a == .inactive or b == .inactive) return .inactive;
        if (a == .sendrecv) return b;
        if (b == .sendrecv) return a;
        return .inactive;
    }

    test "reverse" {
        try testing.expectEqual(.recvonly, Direction.reverse(.sendonly));
        try testing.expectEqual(.sendonly, Direction.reverse(.recvonly));
        try testing.expectEqual(.inactive, Direction.reverse(.inactive));
        try testing.expectEqual(.sendrecv, Direction.reverse(.sendrecv));
    }

    test "intersect" {
        try testing.expectEqual(.sendrecv, Direction.intersect(.sendrecv, .sendrecv));
        try testing.expectEqual(.inactive, Direction.intersect(.sendonly, .recvonly));
        try testing.expectEqual(.inactive, Direction.intersect(.inactive, .sendonly));
        try testing.expectEqual(.inactive, Direction.intersect(.recvonly, .inactive));
        try testing.expectEqual(.sendonly, Direction.intersect(.sendonly, .sendrecv));
        try testing.expectEqual(.recvonly, Direction.intersect(.sendrecv, .recvonly));
    }
};

pub const Init = struct {
    direction: Direction,
    stream_id: ?[]const u8 = null,
};

pub const TrackEventInit = struct {
    receiver: *RtpReceiver,
    track: MediaStreamTrack,
    transceiver: *RtpTransceiver,
};

sender: RtpSender,
receiver: RtpReceiver,
kind: TrackKind,
direction: Direction,
current_direction: ?Direction = null,
fired_direction: ?Direction = null,
mid: ?u24 = null, // mid is 3 bytes at most
sdp_mline_index: ?u8 = null,
stopping: bool = false,
stopped: bool = false,
added_by_add_track: bool = false,
transport: *DtlsTransport,

pub fn initFromSdpMedia(allocator: std.mem.Allocator, io: Io, sdp_media: *const SDPSession.SDPMedia, index: u8) !*RtpTransceiver {
    const tr = try allocator.create(RtpTransceiver);
    errdefer allocator.destroy(tr);

    const track = if (sdp_media.track_id) |track_id|
        MediaStreamTrack.initWithId(track_id, sdp_media.kind)
    else
        MediaStreamTrack.init(io, sdp_media.kind);

    tr.* = .{
        .direction = .recvonly,
        .kind = sdp_media.kind,
        .receiver = try .init(track, allocator),
        .sender = .init(null),
        .mid = sdp_media.mid,
        .sdp_mline_index = index,
        .transport = undefined,
    };

    return tr;
}

pub fn deinit(tr: *RtpTransceiver, io: Io, allocator: std.mem.Allocator) void {
    tr.receiver.deinit(io, allocator);
    allocator.destroy(tr);
}

/// Creates an SDP media description from the transceiver.
///
/// Called when creating offers.
pub fn toSdpMedia(tr: *RtpTransceiver, allocator: std.mem.Allocator) std.mem.Allocator.Error!SDPSession.SDPMedia {
    var media: SDPSession.SDPMedia = .empty;

    media.kind = tr.kind;
    media.port = if (tr.stopping) 0 else 9;
    media.direction = tr.direction;
    media.rtp_codec_parameters = try allocator.dupe(webrtc.RtpCodecParameters, webrtc.getCodecCapabilities(tr.kind));
    media.rtcp_mux = true;
    media.rtcp_rsize = false;
    media.setIceCredentials(tr.transport.ice_agent.credentials);

    try tr.addSenderFields(allocator, &media);
    if (tr.mid) |mid| media.mid = mid;

    return media;
}

/// Creates an answer SDP media description from the transceiver.
pub fn toSdpMediaAnswer(
    tr: *const RtpTransceiver,
    allocator: std.mem.Allocator,
    media: *const SDPSession.SDPMedia,
) std.mem.Allocator.Error!SDPSession.SDPMedia {
    var answer: SDPSession.SDPMedia = .empty;
    errdefer answer.deinit(allocator);

    const codecs = try utils.getCodecIntersection(
        allocator,
        media.rtp_codec_parameters,
        webrtc.getCodecCapabilities(tr.kind),
    );
    defer if (answer.port == 0) allocator.free(codecs);

    const rejected = codecs.len == 0 or tr.isStopped() or media.isRejected();

    answer.kind = tr.kind;
    answer.port = if (rejected) 0 else 9;
    answer.rtcp_mux = true;
    answer.rtcp_rsize = false;
    answer.mid = tr.mid.?;
    answer.setup = switch (media.setup) {
        .active => .passive,
        else => .active,
    };
    answer.direction = media.direction.reverse().intersect(tr.direction);
    answer.rtp_codec_parameters = if (answer.port == 0)
        try allocator.dupe(webrtc.RtpCodecParameters, media.rtp_codec_parameters)
    else
        codecs;
    if (!rejected and answer.direction != .inactive) {
        answer.setIceCredentials(tr.transport.ice_agent.credentials);
    }

    if (!rejected) try tr.addSenderFields(allocator, &answer);
    return answer;
}

/// Check if a track of kind `kind` can be associated with this transceiver.
pub fn canAssociateTrack(tr: *const RtpTransceiver, kind: TrackKind) bool {
    return tr.sender.track == null and
        tr.kind == kind and
        !tr.stopping and
        tr.direction != .sendonly and
        tr.direction != .sendrecv;
}

/// Check if a remote media description can be associated with this transceiver.
pub fn canAssociateMedia(tr: *const RtpTransceiver, media: *const SDPSession.SDPMedia) bool {
    return (media.direction == .sendrecv or media.direction == .recvonly) and
        tr.kind == media.kind and
        tr.mid == null and
        !tr.stopping;
}

pub fn setSenderTrack(tr: *RtpTransceiver, track: MediaStreamTrack) void {
    std.debug.assert(tr.sender.track == null);
    tr.sender.track = track;
    tr.direction = switch (tr.direction) {
        .recvonly => .sendrecv,
        .inactive => .sendonly,
        else => |direction| direction,
    };
}

/// Stops a transceiver.
///
/// Prefer calling PeerConnection `stopTransceiver` instead of calling this directly.
pub fn stop(tr: *RtpTransceiver) void {
    if (!tr.stopping) {
        tr.stopping = true;
        tr.direction = .inactive;
    }
    // TODO: stop sender and receiver
    tr.stopped = true;
    tr.current_direction = null;
}

pub fn isStopped(tr: *const RtpTransceiver) bool {
    return tr.stopping or tr.stopped;
}

/// Removes the track from transceiver.
pub fn removeTrack(tr: *RtpTransceiver) void {
    if (tr.stopping or tr.sender.track == null) return;

    tr.sender.track = null;
    switch (tr.direction) {
        .sendrecv => tr.direction = .recvonly,
        .sendonly => tr.direction = .inactive,
        else => {},
    }
}

pub fn canSend(tr: *const RtpTransceiver) bool {
    if (tr.isStopped()) return false;
    if (tr.current_direction) |direction| return direction == .sendrecv or direction == .sendonly;
    return false;
}

pub fn processRemoteTrack(tr: *RtpTransceiver, direction: Direction, msid: ?MediaStream) ?TrackEventInit {
    tr.receiver.track.stream_id = if (msid) |m| m.id else null;

    // It's safe to set default value to inactive
    // Since it's not included in the clauses that mute tracks and it's included
    // in the clauses that create init track event.
    const fired_direction = tr.fired_direction orelse .inactive;
    tr.fired_direction = direction;

    switch (direction) {
        .sendonly, .inactive => switch (fired_direction) {
            .sendrecv, .recvonly => tr.receiver.track.muted = true,
            else => {},
        },
        .sendrecv, .recvonly => switch (fired_direction) {
            .sendrecv, .recvonly => {},
            else => return TrackEventInit{
                .receiver = &tr.receiver,
                .track = tr.receiver.track,
                .transceiver = tr,
            },
        },
    }

    return null;
}

/// Get rtcp report of the transceiver.
///
/// For now it only gets sender report
pub fn getRtcpReport(tr: *const RtpTransceiver, timestamp: i64, buffer: []u8) []const u8 {
    return switch (tr.direction) {
        .sendrecv, .sendonly => tr.sender.writeReport(timestamp, buffer),
        else => &.{},
    };
}

fn addSenderFields(tr: *const RtpTransceiver, allocator: std.mem.Allocator, media: *SDPSession.SDPMedia) !void {
    switch (tr.direction) {
        .sendonly, .sendrecv => {
            const track = &tr.sender.track.?;
            if (track.stream_id) |stream_id| media.msid = .{ .id = stream_id };
            media.track_id = try allocator.dupe(u8, track.getId());
            media.ssrc = tr.sender.ssrc;
        },
        else => {},
    }
}

fn newTestRtpTransceiver(io: Io, allocator: std.mem.Allocator) !*RtpTransceiver {
    const tr = try allocator.create(RtpTransceiver);

    tr.* = .{
        .sender = .init(.init(io, .video)),
        .receiver = try .init(.init(io, .video), allocator),
        .direction = .sendrecv,
        .kind = .video,
        .transport = undefined,
    };

    return tr;
}

const testing = std.testing;
const rtcp = @import("rtcp");

test "initFromSdpMedia" {
    var sdp_media = SDPSession.SDPMedia.empty;
    sdp_media.mid = 1;

    var tr = try RtpTransceiver.initFromSdpMedia(testing.allocator, testing.io, &sdp_media, 0);
    defer tr.deinit(testing.io, testing.allocator);

    try testing.expectEqual(.video, tr.kind);
    try testing.expectEqual(.recvonly, tr.direction);
    try testing.expectEqual(1, tr.mid);
    try testing.expectEqual(0, tr.sdp_mline_index.?);
    try testing.expect(tr.sender.track == null);
    try testing.expect(!std.mem.eql(u8, &.{}, tr.receiver.track.getId()));

    sdp_media.track_id = "track1";
    var tr2 = try RtpTransceiver.initFromSdpMedia(testing.allocator, testing.io, &sdp_media, 1);
    defer tr2.deinit(testing.io, testing.allocator);

    try testing.expectEqualStrings("track1", tr2.receiver.track.getId());
}

test "toSdpMedia" {
    var transport = try DtlsTransport.init(testing.io, testing.allocator, .{});
    defer transport.deinit();

    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);
    tr.transport = &transport;

    var media = try tr.toSdpMedia(testing.allocator);

    try testing.expectEqual(.video, media.kind);
    try testing.expectEqual(9, media.port);
    try testing.expectEqual(.sendrecv, media.direction);
    try testing.expect(media.mid == 0);
    try testing.expect(media.rtp_codec_parameters.len > 0);
    try testing.expect(media.track_id != null);
    try testing.expectEqualStrings(media.track_id.?, tr.sender.track.?.getId());

    const ice_credentials = transport.ice_agent.credentials;
    try testing.expectEqualStrings(ice_credentials.username, media.ice_ufrag);
    try testing.expectEqualStrings(ice_credentials.password, media.ice_pwd);

    tr.direction = .recvonly;
    tr.sender.track = null;

    media.deinit(testing.allocator);
    media = try tr.toSdpMedia(testing.allocator);
    defer media.deinit(testing.allocator);

    try testing.expectEqual(.recvonly, media.direction);
    try testing.expect(media.track_id == null);
}

test "toSdpMediaAnswer: answer to offer" {
    var transport = try DtlsTransport.init(testing.io, testing.allocator, .{});
    defer transport.deinit();

    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);
    tr.mid = 0x30;
    tr.transport = &transport;

    var offer_media = SDPSession.SDPMedia.empty;
    offer_media.kind = .video;
    offer_media.direction = .sendrecv;
    offer_media.port = 9;
    offer_media.rtp_codec_parameters = try testing.allocator.dupe(webrtc.RtpCodecParameters, webrtc.getCodecCapabilities(.video));
    defer offer_media.deinit(testing.allocator);

    var answer_media = try tr.toSdpMediaAnswer(testing.allocator, &offer_media);
    defer answer_media.deinit(testing.allocator);

    try testing.expectEqual(.video, answer_media.kind);
    try testing.expectEqual(9, answer_media.port);
    try testing.expectEqual(.sendrecv, answer_media.direction);
    try testing.expectEqual(0x30, answer_media.mid);
    try testing.expect(answer_media.rtp_codec_parameters.len == offer_media.rtp_codec_parameters.len);

    const ice_credentials = transport.ice_agent.credentials;
    try testing.expectEqualStrings(ice_credentials.username, answer_media.ice_ufrag);
    try testing.expectEqualStrings(ice_credentials.password, answer_media.ice_pwd);
}

test "toSdpMediaAnswer: reject offer" {
    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);
    tr.mid = 0x30;

    var offer_media = SDPSession.SDPMedia.empty;

    // Offer port == 0
    {
        offer_media.port = 0;
        var answer_media = try tr.toSdpMediaAnswer(testing.allocator, &offer_media);
        defer answer_media.deinit(testing.allocator);
        try testing.expectEqual(.video, answer_media.kind);
        try testing.expectEqual(0, answer_media.port);
        try testing.expect(answer_media.ice_pwd.len == 0);
        try testing.expect(answer_media.ice_ufrag.len == 0);
    }

    // No common codecs
    {
        offer_media.port = 9;
        offer_media.rtp_codec_parameters = &.{};

        var answer_media = try tr.toSdpMediaAnswer(testing.allocator, &offer_media);
        defer answer_media.deinit(testing.allocator);
        try testing.expectEqual(.video, answer_media.kind);
        try testing.expectEqual(0, answer_media.port);
        try testing.expect(answer_media.ice_pwd.len == 0);
        try testing.expect(answer_media.ice_ufrag.len == 0);
    }
}

test "canAssociateTrack" {
    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);
    tr.direction = .recvonly;
    tr.sender.track = null;

    try testing.expect(tr.canAssociateTrack(.video));

    tr.kind = .audio;
    try testing.expect(!tr.canAssociateTrack(.video));

    tr.kind = .video;
    tr.sender.track = .init(testing.io, .video);
    try testing.expect(!tr.canAssociateTrack(.video));

    tr.sender.track = null;
    tr.stopping = true;
    try testing.expect(!tr.canAssociateTrack(.video));
}

test "setSenderTrack" {
    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);
    tr.direction = .recvonly;
    tr.sender.track = null;

    const track = MediaStreamTrack.init(testing.io, .video);
    tr.setSenderTrack(track);

    try testing.expectEqualStrings(track.getId(), tr.sender.track.?.getId());
    try testing.expectEqual(.sendrecv, tr.direction);
}

test "stopTransceiver" {
    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);
    tr.direction = .sendrecv;
    tr.sender.track = .init(testing.io, .video);

    tr.stop();

    try testing.expect(tr.isStopped());
    try testing.expectEqual(.inactive, tr.direction);
}

test "removeTrack" {
    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);

    tr.removeTrack();

    try testing.expect(tr.sender.track == null);
    try testing.expectEqual(.recvonly, tr.direction);

    tr.stop();
    try testing.expectEqual(.inactive, tr.direction);

    tr.removeTrack();
    try testing.expectEqual(.inactive, tr.direction);
}

test "getRtcpReport" {
    var tr = try newTestRtpTransceiver(testing.io, testing.allocator);
    defer tr.deinit(testing.io, testing.allocator);
    tr.sender.codecs = webrtc.getCodecCapabilities(.video);
    var buffer: [64]u8 = @splat(0);

    tr.sender.report = .{
        .last_sequence_number = 0,
        .rtp_timestamp = 8700,
        .timestamp = 1782239529800000,
        .octet_count = 10000,
        .packet_count = 100,
    };

    const data = tr.getRtcpReport(1782239530300000, &buffer);
    const packet = try rtcp.Packet.decode(data);
    try testing.expectEqual(.sender_report, packet.header.payload_type);
    try testing.expectEqual(tr.sender.ssrc, packet.payload.sr.ssrc);
    try testing.expectEqual(53700, packet.payload.sr.rtp_timestamp);
    try testing.expectEqual(17142195148218995680, packet.payload.sr.ntp_timestamp);
    try testing.expectEqual(10000, packet.payload.sr.octet_count);
    try testing.expectEqual(100, packet.payload.sr.packet_count);
}

test "processRemoteTrack" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tr = try newTestRtpTransceiver(testing.io, allocator);
    defer tr.deinit(io, allocator);

    var maybe_event = tr.processRemoteTrack(.sendrecv, null);
    try testing.expect(maybe_event != null);
    try testing.expect(maybe_event.?.transceiver == tr);
    try testing.expect(tr.fired_direction == .sendrecv);

    maybe_event = tr.processRemoteTrack(.recvonly, null);
    try testing.expect(maybe_event == null);

    maybe_event = tr.processRemoteTrack(.inactive, null);
    try testing.expect(maybe_event == null);
    try testing.expect(tr.receiver.track.muted);

    maybe_event = tr.processRemoteTrack(.recvonly, null);
    try testing.expect(maybe_event != null);
}
