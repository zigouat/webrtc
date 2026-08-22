const std = @import("std");
const webrtc = @import("../webrtc.zig");

const MediaEngine = @This();
const TrackKind = webrtc.TrackKind;
const RtpCodec = webrtc.RtpCodec;
const RtpCodecParameters = webrtc.RtpCodecParameters;

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

/// Codecs MediaEngine accepts via registerCodec, and the payload types assigned to them.
pub const supported_video_codecs = &[_]RtpCodecParameters{
    .{
        .payload_type = 96,
        .rtp_codec = .{
            .mime_type = MimeType.VP8,
            .clock_rate = 90_000,
            .rtcp_feedbacks = .{ .nack_pli = true },
        },
    },
    .{
        .payload_type = 104,
        .rtp_codec = .{
            .mime_type = MimeType.H264,
            .clock_rate = 90_000,
            .fmtp_params = .{
                .h264 = .{
                    .profile_level_id = 0x42e01f,
                    .level_asymmetry_allowed = true,
                    .packetization_mode = 1,
                },
            },
            .rtcp_feedbacks = .{ .nack_pli = true },
        },
    },
};

pub const supported_audio_codecs = &[_]RtpCodecParameters{
    .{
        .payload_type = 111,
        .rtp_codec = .{
            .mime_type = MimeType.Opus,
            .clock_rate = 48_000,
            .channels = 2,
        },
    },
};

pub const Error = error{UnsupportedCodec} || std.mem.Allocator.Error;

pub const Config = struct {
    enable_rtx: bool = false,
};

video_codecs: std.ArrayList(RtpCodecParameters),
audio_codecs: std.ArrayList(RtpCodecParameters),
enable_rtx: bool,

pub fn init(config: Config) MediaEngine {
    return .{
        .audio_codecs = .empty,
        .video_codecs = .empty,
        .enable_rtx = config.enable_rtx,
    };
}

pub fn deinit(self: *MediaEngine, allocator: std.mem.Allocator) void {
    self.video_codecs.deinit(allocator);
    self.audio_codecs.deinit(allocator);
}

/// Registers a new codec.
pub fn registerCodec(self: *MediaEngine, allocator: std.mem.Allocator, kind: TrackKind, codec: RtpCodec) Error!void {
    const supported: []const RtpCodecParameters = switch (kind) {
        .video => supported_video_codecs,
        .audio => supported_audio_codecs,
    };
    const list: *std.ArrayList(RtpCodecParameters) = switch (kind) {
        .video => &self.video_codecs,
        .audio => &self.audio_codecs,
    };

    const payload_type = for (supported) |candidate| {
        if (candidate.rtp_codec.eql(&codec)) break candidate.payload_type;
    } else return error.UnsupportedCodec;

    const params = RtpCodecParameters{ .payload_type = payload_type, .rtp_codec = codec };
    for (list.items) |*existing| {
        if (existing.eql(&params)) return;
    }

    const list_len = list.items.len;
    errdefer list.shrinkRetainingCapacity(list_len);
    try list.append(allocator, params);

    if (kind == .video and self.enable_rtx) {
        try list.append(allocator, .{
            .payload_type = payload_type + 1,
            .rtp_codec = .{
                .mime_type = MimeType.Rtx,
                .clock_rate = codec.clock_rate,
                .fmtp_params = .{ .rtx = .{ .apt = payload_type } },
            },
        });
    }
}

/// Registers every codec in the fixed supported-codec list. Rolls back on partial failure.
pub fn registerDefaultCodecs(self: *MediaEngine, allocator: std.mem.Allocator) Error!void {
    const video_len = self.video_codecs.items.len;
    errdefer self.video_codecs.shrinkRetainingCapacity(video_len);

    const audio_len = self.audio_codecs.items.len;
    errdefer self.audio_codecs.shrinkRetainingCapacity(audio_len);

    for (supported_video_codecs) |codec| {
        try self.registerCodec(allocator, .video, codec.rtp_codec);
    }
    for (supported_audio_codecs) |codec| {
        try self.registerCodec(allocator, .audio, codec.rtp_codec);
    }
}

test "registerCodec stores a supported codec with its payload type" {
    const allocator = std.testing.allocator;
    var engine = MediaEngine.init(.{});
    defer engine.deinit(allocator);

    try engine.registerCodec(allocator, .video, .{ .mime_type = MimeType.VP8, .clock_rate = 90_000 });

    try std.testing.expectEqual(@as(usize, 1), engine.video_codecs.items.len);
    try std.testing.expectEqual(@as(u8, 96), engine.video_codecs.items[0].payload_type);
}

test "registerCodec rejects an unsupported codec" {
    const allocator = std.testing.allocator;
    var engine = MediaEngine.init(.{});
    defer engine.deinit(allocator);

    try std.testing.expectError(error.UnsupportedCodec, engine.registerCodec(allocator, .video, .{ .mime_type = "video/foo", .clock_rate = 90_000 }));
}

test "registerCodec ignores a duplicate codec" {
    const allocator = std.testing.allocator;
    var engine = MediaEngine.init(.{});
    defer engine.deinit(allocator);

    const codec: RtpCodec = .{ .mime_type = MimeType.VP8, .clock_rate = 90_000 };
    try engine.registerCodec(allocator, .video, codec);
    try engine.registerCodec(allocator, .video, codec);

    try std.testing.expectEqual(@as(usize, 1), engine.video_codecs.items.len);
}

test "registerDefaultCodecs registers every supported codec exactly once" {
    const allocator = std.testing.allocator;
    var engine = MediaEngine.init(.{});
    defer engine.deinit(allocator);

    try engine.registerDefaultCodecs(allocator);
    try engine.registerDefaultCodecs(allocator);

    try std.testing.expectEqual(supported_video_codecs.len, engine.video_codecs.items.len);
    try std.testing.expectEqual(supported_audio_codecs.len, engine.audio_codecs.items.len);
}

test "registerCodec adds an rtx companion codec when enable_rtx is set" {
    const allocator = std.testing.allocator;
    var engine = MediaEngine.init(.{ .enable_rtx = true });
    defer engine.deinit(allocator);

    try engine.registerCodec(allocator, .video, .{ .mime_type = MimeType.VP8, .clock_rate = 90_000 });

    try std.testing.expectEqual(@as(usize, 2), engine.video_codecs.items.len);
    try std.testing.expectEqual(@as(u8, 97), engine.video_codecs.items[1].payload_type);
    try std.testing.expect(std.ascii.eqlIgnoreCase(engine.video_codecs.items[1].rtp_codec.mime_type, MimeType.Rtx));
}
