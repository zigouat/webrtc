pub const PeerConnection = @import("peer_connection.zig");
pub const SDPSession = @import("sdp_session.zig");
pub const RtpTransceiver = @import("rtp_transceiver.zig");
pub const RtpSender = @import("rtp_sender.zig");
pub const RtpReceiver = @import("rtp_receiver.zig");

const std = @import("std");
const sdp = @import("sdp");

const Io = std.Io;
const FmtpParams = sdp.Attribute.Fmtp.Params;
const testing = std.testing;

pub const ntp_unix_epoch_diff = 2_208_988_800;

/// Default video codecs used for sending and receiving video tracks.
///
/// This can be overridden by the user to only include the codecs they want to support.
pub const default_video_codecs = &[_]RtpCodecParameters{
    .{
        .payload_type = 96,
        .mime_type = MimeType.VP8,
        .clock_rate = 90_000,
    },
    .{
        .payload_type = 104,
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

/// Default audio codecs used for sending and receiving audio tracks.
pub const default_audio_codecs = &[_]RtpCodecParameters{
    .{
        .payload_type = 111,
        .mime_type = MimeType.Opus,
        .clock_rate = 48_000,
        .channels = 2,
    },
};

pub const MimeType = struct {
    pub const H264 = "video/H264";
    pub const H265 = "video/H265";
    pub const VP8 = "video/VP8";
    pub const VP9 = "video/VP9";
    pub const AV1 = "video/AV1";
    pub const Rtx = "video/rtx";
    pub const Ulpfec = "video/ulpfec";
    pub const Red = "video/red";
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

pub const default_video_extensions = [_]RtpHeaderExtensionParameter{
    .{ .id = 1, .uri = "urn:ietf:params:rtp-hdrext:sdes:mid" },
};

pub const RtpHeaderExtensionParameter = struct {
    uri: []const u8,
    id: u16,

    pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
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

    pub fn format(codec_params: @This(), writer: *Io.Writer) !void {
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
        if (std.ascii.eqlIgnoreCase(a.mime_type, MimeType.VP8) or
            std.ascii.eqlIgnoreCase(a.mime_type, MimeType.Opus)) return true;

        if (a.fmtp_params != null and b.fmtp_params == null or a.fmtp_params == null and b.fmtp_params != null) return false;
        if (a.fmtp_params) |a_fmtp| if (b.fmtp_params) |*b_fmtp| return a_fmtp.eql(b_fmtp);
        return true;
    }

    pub fn isUnknown(a: *const RtpCodecParameters) bool {
        return std.ascii.eqlIgnoreCase(a.mime_type, MimeType.video_unknown) or
            std.ascii.eqlIgnoreCase(a.mime_type, MimeType.audio_unknown);
    }

    test "eql" {
        {
            const a: RtpCodecParameters = .{ .payload_type = 96, .mime_type = MimeType.H264, .clock_rate = 9000 };
            const b: RtpCodecParameters = .{ .payload_type = 107, .mime_type = MimeType.H264, .clock_rate = 9000 };
            try testing.expect(a.eql(&b));
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

/// TrackKind represents the kind of media track, either audio or video.
pub const TrackKind = enum { audio, video };

/// SessionDescriptionType represents the type of session description.
pub const SessionDescriptionType = enum {
    /// The session description is an offer.
    offer,
    /// The session description is an provisional answer.
    pranswer,
    /// The session description is a final answer.
    answer,
    /// The session description is a rollback of the previous description.
    rollback,
};

pub const SessionDescription = struct {
    type: SessionDescriptionType,
    sdp: []const u8,

    pub fn deinit(sess_desc: *SessionDescription, allocator: std.mem.Allocator) void {
        allocator.free(sess_desc.sdp);
    }
};

pub const MediaStream = struct {
    id: []const u8,

    pub fn init(allocator: std.mem.Allocator, id: []const u8) !MediaStream {
        const id_copy = try allocator.dupe(u8, id);
        return MediaStream{ .id = id_copy };
    }

    pub fn deinit(stream: *MediaStream, allocator: std.mem.Allocator) void {
        allocator.free(stream.id);
    }
};

pub const MediaStreamTrack = struct {
    id: [64]u8,
    kind: TrackKind,
    stream_id: ?[]const u8,
    muted: bool,

    /// Init a new track with generated id.
    ///
    /// Th io instance is needed to generate an id
    pub fn init(io: Io, kind: TrackKind) MediaStreamTrack {
        var buf: [16]u8 = undefined;
        io.random(&buf);

        var track: MediaStreamTrack = .{
            .id = @splat(0),
            .kind = kind,
            .stream_id = null,
            .muted = false,
        };

        @memcpy(track.id[0..32], &std.fmt.bytesToHex(buf, .lower));
        return track;
    }

    pub fn initWithId(id: []const u8, kind: TrackKind) MediaStreamTrack {
        std.debug.assert(id.len <= 64);
        var track: MediaStreamTrack = .{
            .id = @splat(0),
            .kind = kind,
            .stream_id = null,
            .muted = false,
        };

        @memcpy(track.id[0..id.len], id);
        return track;
    }

    pub fn getId(track: *const MediaStreamTrack) []const u8 {
        return std.mem.sliceTo(&track.id, 0);
    }

    test "init" {
        const track = init(testing.io, .video);
        try testing.expect(!std.mem.eql(u8, &.{}, track.getId()));
    }

    test "getId" {
        const track = initWithId("test-track", .audio);
        try testing.expectEqualStrings("test-track", track.getId());
    }
};

pub fn getCodecCapabilities(kind: TrackKind) []const RtpCodecParameters {
    return switch (kind) {
        .audio => default_audio_codecs,
        .video => default_video_codecs,
    };
}

test {
    testing.refAllDecls(@This());
    _ = @import("peer_connection.zig");
    _ = @import("sdp_session.zig");
    _ = @import("rtp_transceiver.zig");
    _ = @import("rtp_sender.zig");
    _ = @import("mid.zig");
}
