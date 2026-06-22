pub const PeerConnection = @import("peer_connection.zig");
pub const SDPSession = @import("sdp_session.zig");

const sdp = @import("sdp");
const rtp = @import("rtp");
const utils = @import("utils.zig");
const FmtpParams = sdp.Attribute.Fmtp.Params;

const std = @import("std");
const DtlsTransport = @import("dtls_transport.zig");

pub const SignalingState = enum { stable, have_local_offer, have_remote_offer, have_local_pranswer, have_remote_pranswer, closed };

pub const ConnectionState = enum { new, connecting, connected, disconnected, failed, closed };

pub const MimeType = struct {
    pub const H264 = "video/H264";
    pub const H265 = "video/H265";
    pub const VP8 = "video/VP8";
    pub const VP9 = "video/VP9";
    pub const AV1 = "video/AV1";
    pub const Rtx = "video/rtx";
    pub const video_unknown = "video/unknown";
    pub const Opus = "audio/Opus";
    pub const G722 = "audio/G722";
    pub const PCMU = "audio/PCMU";
    pub const PCMA = "audio/PCMA";
    pub const audio_unknown = "audio/unknown";

    pub fn fromKindAndCodec(kind: TrackKind, codec: []const u8) []const u8 {
        switch (kind) {
            .video => return if (std.ascii.eqlIgnoreCase(codec, "h264"))
                H264
            else if (std.ascii.eqlIgnoreCase(codec, "h265"))
                H265
            else if (std.ascii.eqlIgnoreCase(codec, "rtx"))
                Rtx
            else if (std.ascii.eqlIgnoreCase(codec, "vp8"))
                VP8
            else if (std.ascii.eqlIgnoreCase(codec, "vp9"))
                VP9
            else if (std.ascii.eqlIgnoreCase(codec, "av1"))
                AV1
            else
                video_unknown,
            .audio => return if (std.ascii.eqlIgnoreCase(codec, "opus"))
                Opus
            else if (std.ascii.eqlIgnoreCase(codec, "g722"))
                G722
            else if (std.ascii.eqlIgnoreCase(codec, "pcmu"))
                PCMU
            else if (std.ascii.eqlIgnoreCase(codec, "pcma"))
                PCMA
            else
                audio_unknown,
        }
    }
};

pub const default_video_codecs = [_]RtpCodecParameters{
    .{
        .payload_type = 96,
        .mime_type = MimeType.H264,
        .clock_rate = 90_000,
        .fmtp_params = .{
            .h264 = .{
                .profile_level_id = 0x42e01f,
                .level_asymmetry_allowed = true,
                .packetization_mode = 1,
            },
        },
    },
};

pub const default_video_extensions = [_]RtpHeaderExtensionParameter{
    .{ .id = 1, .uri = "urn:ietf:params:rtp-hdrext:sdes:mid" },
};

pub const RtpHeaderExtensionParameter = struct {
    uri: []const u8,
    id: u16,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const attr = sdp.Attribute.ParsedAttribute{ .extmap = .{ .id = self.id, .uri = self.uri } };
        try attr.write(writer);
    }
};

pub const RtcpParameter = struct {
    cname: []const u8,
    reduced_size: bool,
};

pub const RtpCodecParameters = struct {
    payload_type: u8,
    mime_type: []const u8,
    clock_rate: u32,
    channels: ?u8 = null,
    fmtp_params: ?FmtpParams = null,

    pub fn format(codec_params: @This(), writer: *std.Io.Writer) !void {
        try sdp.Attribute.ParsedAttribute.write(.{
            .rtpmap = .{
                .clock_rate = codec_params.clock_rate,
                .encoding = std.mem.cut(u8, codec_params.mime_type, "/").?.@"1",
                .payload_type = codec_params.payload_type,
                .channels = codec_params.channels,
            },
        }, writer);

        if (codec_params.fmtp_params) |params| {
            try writer.print("a=fmtp:{} {f}\r\n", .{ codec_params.payload_type, params });
        }
    }

    pub fn isRtx(a: *const RtpCodecParameters) bool {
        const codec = std.mem.cutScalar(u8, a.mime_type, '/').?.@"1";
        return std.ascii.eqlIgnoreCase(codec, "rtx");
    }

    pub fn eql(a: *const RtpCodecParameters, b: *const RtpCodecParameters) bool {
        if (!std.ascii.eqlIgnoreCase(a.mime_type, b.mime_type) or
            a.clock_rate != b.clock_rate or
            a.channels != b.channels) return false;
        if (a.fmtp_params != null and b.fmtp_params == null or a.fmtp_params == null and b.fmtp_params != null) return false;
        if (a.fmtp_params) |a_fmtp| if (b.fmtp_params) |*b_fmtp| return a_fmtp.eql(b_fmtp);
        return true;
    }

    test "eql" {
        {
            const a: RtpCodecParameters = .{ .payload_type = 96, .mime_type = MimeType.H264, .clock_rate = 9000 };
            const b: RtpCodecParameters = .{ .payload_type = 107, .mime_type = MimeType.H264, .clock_rate = 9000 };
            try std.testing.expect(a.eql(&b));
        }
    }
};

pub const RtpParameters = struct {
    header_extensions: []RtpHeaderExtensionParameter,
    rtcp: RtcpParameter,
    codecs: []RtpCodecParameters,
};

pub const RtpCapabilities = struct {
    codecs: []const RtpCodecParameters,
    header_extensions: []RtpHeaderExtensionParameter,
};

pub const Direction = enum {
    sendrecv,
    sendonly,
    recvonly,
    inactive,
    stopped,

    pub fn reverse(direction: Direction) Direction {
        std.debug.assert(direction != .stopped);

        return switch (direction) {
            .sendonly => .recvonly,
            .recvonly => .sendonly,
            .inactive, .sendrecv => |d| d,
            else => unreachable,
        };
    }

    pub fn intersect(a: Direction, b: Direction) Direction {
        std.debug.assert(a != .stopped and b != .stopped);

        if (a == b) return a;
        if (a == .inactive or b == .inactive) return .inactive;
        if (a == .sendrecv) return b;
        if (b == .sendrecv) return a;
        return .inactive;
    }
};

pub const TrackKind = enum { audio, video };

pub const SessionDescriptionType = enum { offer, pranswer, answer, rollback };

pub const SessionDescription = struct {
    desc_type: SessionDescriptionType,
    sdp: []const u8,

    pub fn deinit(sess_desc: *SessionDescription, allocator: std.mem.Allocator) void {
        allocator.free(sess_desc.sdp);
    }
};

pub const MediaStreamTrack = struct {
    id: []const u8,
    stream_id: ?[]const u8 = null,
    kind: TrackKind,
};

pub const RtpSender = struct {
    track: ?MediaStreamTrack = null,
    codecs: []const RtpCodecParameters = &.{},

    pub fn getCapabilities(kind: TrackKind) RtpCapabilities {
        _ = kind;
        return .{ .codecs = &.{}, .header_extensions = &.{} };
    }

    pub fn replaceTrack(sender: *RtpSender, new_track: MediaStreamTrack) !void {
        _ = sender;
        _ = new_track;
        @panic("Not Implemented");
    }

    pub fn sendRtp(sender: *RtpSender, packet: *const rtp.Packet) !void {
        const tr: *RtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
        var buffer = try tr.transport.ice_agent.createPacket();
        defer tr.transport.ice_agent.destroyPacket(buffer);

        const header: rtp.Packet.Header = .{
            .extension = false,
            .marker = packet.header.marker,
            .padding = false,
            .payload_type = @intCast(tr.sender.codecs[0].payload_type),
            .sequence_number = packet.header.sequence_number,
            .ssrc = 0x18192021,
            .timestamp = packet.header.timestamp,
        };

        std.mem.writeInt(u96, buffer[0..12], @bitCast(header), .big);
        @memcpy(buffer[12 .. packet.payload.len + 12], packet.payload);
        try tr.transport.sendRtp(buffer[0 .. packet.payload.len + 12]);
    }
};

pub const RtpReceiver = struct {
    track: MediaStreamTrack,
    codecs: []const RtpCodecParameters = &.{},

    pub fn init(kind: TrackKind) RtpReceiver {
        return .{ .track = .{ .id = "recv-track", .kind = kind } };
    }

    pub fn getCapabilities(kind: TrackKind) RtpCapabilities {
        _ = kind;
        return .{ .codecs = &.{}, .header_extensions = &.{} };
    }

    pub fn handleRtpPacket(receiver: *RtpReceiver, packet: rtp.Packet) !?rtp.Packet {
        _ = receiver;
        return packet;
    }
};

pub const RtpTransceiver = struct {
    sender: RtpSender,
    receiver: RtpReceiver,
    kind: TrackKind,
    direction: Direction,
    current_direction: ?Direction = null,
    mid: ?[]const u8 = null,
    sdp_mline_index: ?u8 = null,
    stopping: bool = false,
    addedByAddTrack: bool = false,
    transport: *DtlsTransport,

    pub fn initFromTrack(allocator: std.mem.Allocator, track: MediaStreamTrack, transport: *DtlsTransport) !*RtpTransceiver {
        const tr = try allocator.create(RtpTransceiver);
        tr.* = .{
            .kind = track.kind,
            .direction = .sendrecv,
            .sender = .{ .track = track },
            .receiver = .init(track.kind),
            .addedByAddTrack = true,
            .transport = transport,
        };

        return tr;
    }

    pub fn initFromKind(allocator: std.mem.Allocator, kind: TrackKind, transport: *DtlsTransport) !*RtpTransceiver {
        const tr = try allocator.create(RtpTransceiver);
        tr.* = .{
            .kind = kind,
            .direction = .sendrecv,
            .sender = .{ .track = null },
            .receiver = .init(kind),
            .addedByAddTrack = true,
            .transport = transport,
        };

        return tr;
    }

    pub fn initFromSdpMedia(allocator: std.mem.Allocator, sdp_media: *const SDPSession.SDPMedia, index: u8) !*RtpTransceiver {
        const tr = try allocator.create(RtpTransceiver);
        tr.* = .{
            .direction = .recvonly,
            .kind = sdp_media.kind,
            .receiver = .init(sdp_media.kind),
            .sender = .{},
            .mid = &sdp_media.mid,
            .sdp_mline_index = index,
            .transport = undefined,
        };

        return tr;
    }

    pub fn deinit(tr: *RtpTransceiver, allocator: std.mem.Allocator) void {
        allocator.destroy(tr);
    }

    pub fn toSdpMedia(tr: *RtpTransceiver, allocator: std.mem.Allocator) !SDPSession.SDPMedia {
        var media: SDPSession.SDPMedia = .empty;

        media.kind = tr.kind;
        media.port = if (tr.current_direction == .stopped) 0 else 9;
        media.direction = tr.direction;
        media.rtp_codec_parameters = try allocator.dupe(RtpCodecParameters, getCodecCapabilities(tr.kind));
        media.rtcp_mux = true;
        media.rtcp_rsize = false;
        media.setIceCredentials(tr.transport.ice_agent.credentials);

        if (tr.mid) |mid| @memcpy(media.mid[0..mid.len], mid);

        return media;
    }

    /// Check if a track of kind `kind` can be associated with this transceiver.
    pub fn canAssociateTrack(tr: *const RtpTransceiver, kind: TrackKind) bool {
        return tr.sender.track == null and
            tr.kind == kind and
            !tr.stopping and
            tr.direction != .sendonly and
            tr.direction != .sendrecv;
    }

    pub fn canAssociateMedia(tr: *const RtpTransceiver, media: *const SDPSession.SDPMedia) bool {
        return (media.direction == .sendrecv or media.direction == .recvonly) and
            tr.kind == media.kind and
            tr.mid == null and
            tr.direction != .stopped;
    }

    pub fn setSenderTrack(tr: *RtpTransceiver, track: MediaStreamTrack) void {
        tr.sender.track = track;
        tr.direction = switch (tr.direction) {
            .recvonly => .sendrecv,
            .inactive => .sendonly,
            else => |direction| direction,
        };
    }

    pub fn stop(tr: *RtpTransceiver) void {
        if (tr.direction != .stopped) tr.stopping = true;
        tr.direction = .stopped;
        tr.current_direction = null;
        // TODO: stop sender and receiver
    }

    test "canAssocaiteTrack" {
        var tr: RtpTransceiver = .{
            .sender = .{},
            .receiver = .{ .track = .{ .id = "track", .kind = .video } },
            .direction = .recvonly,
            .kind = .video,
            .transport = undefined,
        };

        try std.testing.expect(tr.canAssociateTrack(.video));

        tr.kind = .audio;
        try std.testing.expect(!tr.canAssociateTrack(.video));

        tr.kind = .video;
        tr.sender.track = .{ .id = "track-1", .kind = .video };
        try std.testing.expect(!tr.canAssociateTrack(.video));

        tr.sender.track = null;
        tr.stopping = true;
        try std.testing.expect(!tr.canAssociateTrack(.video));
    }
};

pub fn getCodecCapabilities(kind: TrackKind) []const RtpCodecParameters {
    return switch (kind) {
        .audio => &.{},
        .video => &default_video_codecs,
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("peer_connection.zig");
    _ = @import("sdp_session.zig");
}
