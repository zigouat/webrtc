const std = @import("std");
const sdp = @import("sdp");
const ice = @import("ice");
const webrtc = @import("webrtc.zig");

const SDPSession = @This();
const SDPAttribute = sdp.Attribute.ParsedAttribute;

const sdp_header =
    \\v=0
    \\o=- 1000 1779396395 IN IP4 0.0.0.0
    \\s=-
    \\t=0 0
    \\a=msid-semantic: WMS *
    \\
;

pub const SDPError = error{
    ParseError,
    MissingBundle,
    InvalidAttribute,
};

pub const Error = SDPError || std.mem.Allocator.Error;

fingerprint: [32]u8,
bundle: []const u8,
ice_lite: bool,
medias: std.ArrayList(SDPMedia),

pub const empty: SDPSession = .{
    .fingerprint = @splat(0),
    .bundle = &.{},
    .ice_lite = false,
    .medias = .empty,
};

pub const SDPMedia = struct {
    kind: webrtc.TrackKind,
    port: u16,
    bundle_only: bool,
    rtp_codec_parameters: []webrtc.RtpCodecParameters,
    rtp_header_extensions: []webrtc.RtpHeaderExtensionParameter,
    mid: [3]u8,
    direction: webrtc.Direction,
    ice_ufrag: []const u8,
    ice_pwd: []const u8,
    candidates: []ice.Candidate,
    end_of_candidates: bool,
    setup: sdp.Attribute.Setup,
    fingerprint: ?[32]u8,
    rtcp_mux: bool,
    rtcp_rsize: bool,
    track: ?webrtc.MediaStreamTrack,
    ssrc: ?u32,

    pub const empty: SDPMedia = .{
        .kind = .video,
        .port = 0,
        .bundle_only = false,
        .rtp_codec_parameters = &.{},
        .rtp_header_extensions = &.{},
        .mid = @splat(0),
        .direction = .sendrecv,
        .ice_ufrag = "",
        .ice_pwd = "",
        .candidates = &.{},
        .end_of_candidates = false,
        .fingerprint = null,
        .setup = .actpass,
        .rtcp_mux = false,
        .rtcp_rsize = false,
        .track = null,
        .ssrc = null,
    };

    pub fn parse(allocator: std.mem.Allocator, media: sdp.Media, fingerprint: *[32]u8) !SDPMedia {
        var sdp_media: SDPMedia = .empty;
        errdefer sdp_media.deinit(allocator);

        sdp_media.kind = switch (media.media_type) {
            .audio => .audio,
            .video => .video,
            else => unreachable,
        };
        sdp_media.port = media.port_range.port;

        // Parse foarmts
        var rtp_codec_parameters: std.ArrayList(webrtc.RtpCodecParameters) = .empty;
        errdefer rtp_codec_parameters.deinit(allocator);

        var rtp_header_extensions: std.ArrayList(webrtc.RtpHeaderExtensionParameter) = .empty;
        errdefer rtp_header_extensions.deinit(allocator);

        var fmt_iterator = std.mem.tokenizeScalar(u8, media.formats, ' ');
        while (fmt_iterator.next()) |payload_type| {
            const pt = try std.fmt.parseInt(u8, payload_type, 10);
            try rtp_codec_parameters.append(allocator, webrtc.RtpCodecParameters{
                .payload_type = pt,
                .clock_rate = 0,
                .mime_type = &.{},
            });
        }

        var candidates: std.ArrayList(ice.Candidate) = .empty;
        errdefer candidates.deinit(allocator);

        // Hold fmtp lines until rtpmap is encountered
        var fmtps: std.AutoHashMap(u8, []const u8) = .init(allocator);
        defer fmtps.deinit();

        var attr_it = media.attributeIterator();
        while (try attr_it.next()) |attr| switch (try attr.parse()) {
            .bundle_only => sdp_media.bundle_only = true,
            .mid => |v| {
                if (v.len > 3) return error.InvalidSDP;
                @memcpy(sdp_media.mid[0..v.len], v);
            },
            .setup => |v| sdp_media.setup = v,
            .direction => |v| sdp_media.direction = std.meta.stringToEnum(webrtc.Direction, v) orelse .sendrecv,
            .ice_ufrag => |v| sdp_media.ice_ufrag = v,
            .ice_pwd => |v| sdp_media.ice_pwd = v,
            .candidate => |v| {
                const candidate = ice.Candidate.parse(v) catch {
                    std.log.warn("Failed to parse candidate: {s}", .{v});
                    continue;
                };
                try candidates.append(allocator, candidate);
            },
            .end_of_candidates => sdp_media.end_of_candidates = true,
            .rtcp_mux => sdp_media.rtcp_mux = true,
            .rtcp_rsize => sdp_media.rtcp_rsize = true,
            .rtpmap => |rtpmap| {
                const rtp_codec = findRtpCodecParameters(rtp_codec_parameters, rtpmap.payload_type) orelse return error.InvalidRtpMap;
                rtp_codec.clock_rate = rtpmap.clock_rate;
                rtp_codec.channels = rtpmap.channels;
                rtp_codec.mime_type = webrtc.MimeType.fromKindAndCodec(sdp_media.kind, rtpmap.encoding);

                if (fmtps.get(rtp_codec.payload_type)) |fmtp_line| {
                    try setRtpCodecParameterFmtp(rtp_codec, fmtp_line);
                    _ = fmtps.remove(rtp_codec.payload_type);
                }
            },
            .fmtp => |fmtp| {
                const pt, const fmtp_line = fmtp;
                const rtp_codec = findRtpCodecParameters(rtp_codec_parameters, pt) orelse return error.InvalidFmtp;
                if (rtp_codec.mime_type.len == 0) {
                    try fmtps.put(pt, fmtp_line);
                } else {
                    try setRtpCodecParameterFmtp(rtp_codec, fmtp_line);
                }
            },
            .fingerprint => |value| switch (value) {
                .sha_256 => |f| @memcpy(fingerprint, &f),
                else => {},
            },
            .extmap => |extmap| try rtp_header_extensions.append(allocator, .{
                .id = @intCast(extmap.id),
                .uri = extmap.uri,
            }),
            .msid => |msid| if (msid.app_data) |track_id| {
                if (sdp_media.track == null) {
                    sdp_media.track = .initWithId(track_id, sdp_media.kind);
                }
                try sdp_media.track.?.streams.append(allocator, msid.id);
            },
            .ssrc => |ssrc| if (sdp_media.ssrc == null) {
                sdp_media.ssrc = ssrc.id;
            },
            else => {},
        };

        if (!sdp_media.rtcp_mux) return error.RtcpMuxRequired;
        if (sdp_media.mid.len == 0) return error.MidAttributeRequired;

        try validateRtpCodecParameters(rtp_codec_parameters);

        sdp_media.rtp_codec_parameters = try rtp_codec_parameters.toOwnedSlice(allocator);
        sdp_media.rtp_header_extensions = try rtp_header_extensions.toOwnedSlice(allocator);
        sdp_media.candidates = try candidates.toOwnedSlice(allocator);
        return sdp_media;
    }

    pub fn deinit(m: *SDPMedia, allocator: std.mem.Allocator) void {
        allocator.free(m.rtp_codec_parameters);
        allocator.free(m.rtp_header_extensions);
        allocator.free(m.candidates);
        if (m.track) |*track| track.deinit(allocator);
    }

    pub fn hasPayload(media: *const SDPMedia, pt: u8) bool {
        for (media.rtp_codec_parameters) |*codec| if (codec.payload_type == pt) return true;
        return false;
    }

    pub fn write(media: *const SDPMedia, w: *std.Io.Writer) !void {
        try w.print("m={s} {} UDP/TLS/RTP/SAVPF", .{ @tagName(media.kind), media.port });
        for (media.rtp_codec_parameters) |*codec| try w.print(" {}", .{codec.payload_type});
        try w.writeAll("\r\n");
        try w.writeAll("c=IN IP4 0.0.0.0\r\n");
        if (media.bundle_only) try SDPAttribute.write(.bundle_only, w);
        for (media.rtp_codec_parameters) |*codec| try codec.format(w);
        for (media.rtp_header_extensions) |*ext| try ext.format(w);
        try SDPAttribute.write(.{ .setup = media.setup }, w);
        try SDPAttribute.write(.{ .direction = @tagName(media.direction) }, w);
        if (media.getMid().len != 0) try SDPAttribute.write(.{ .mid = media.getMid() }, w);
        if (media.rtcp_mux) try SDPAttribute.write(.rtcp_mux, w);
        if (media.rtcp_rsize) try SDPAttribute.write(.rtcp_rsize, w);

        if (media.ice_ufrag.len != 0) try SDPAttribute.write(.{ .ice_ufrag = media.ice_ufrag }, w);
        if (media.ice_pwd.len != 0) try SDPAttribute.write(.{ .ice_pwd = media.ice_pwd }, w);

        for (media.candidates) |candidate| try w.print("a=candidate:{f}\r\n", .{candidate});
        if (media.end_of_candidates) try SDPAttribute.write(.end_of_candidates, w);
        if (media.track) |track| for (track.streams.items) |msid| {
            try w.print("a=msid:{s} {s}\r\n", .{ msid, track.id });
        };

        if (media.ssrc) |ssrc| {
            const msid = if (media.track != null and media.track.?.streams.items.len > 0) media.track.?.streams.items[0] else "-";
            try w.print("a=ssrc:{} msid:{s} {s}\r\n", .{ ssrc, msid, media.track.?.getId() });
        }
    }

    pub fn setIceCredentials(media: *SDPMedia, credens: ice.Credentials) void {
        media.ice_ufrag = credens.username;
        media.ice_pwd = credens.password;
    }

    pub fn getMid(media: *const SDPMedia) []const u8 {
        return std.mem.sliceTo(&media.mid, 0);
    }

    pub fn isRejected(media: *const SDPMedia) bool {
        return media.port == 0 and !media.bundle_only;
    }

    pub fn clone(media: *const SDPMedia, allocator: std.mem.Allocator) !SDPMedia {
        var new_media = media.*;
        new_media.rtp_codec_parameters = try allocator.dupe(webrtc.RtpCodecParameters, media.rtp_codec_parameters);
        new_media.rtp_header_extensions = try allocator.dupe(webrtc.RtpHeaderExtensionParameter, media.rtp_header_extensions);
        return new_media;
    }

    fn validateRtpCodecParameters(rtp_codec_parameters: std.ArrayList(webrtc.RtpCodecParameters)) !void {
        for (rtp_codec_parameters.items) |*rtp_codec| {
            if (rtp_codec.mime_type.len == 0) return error.InvalidMedia; // no rtpmap entry exists

            // Check the associated codec with this rtx
            if (rtp_codec.isRtx()) {
                if (rtp_codec.fmtp_params == null) return error.InvalidMedia;
                const apt = rtp_codec.fmtp_params.?.rtx.apt;
                const associated_codec = findRtpCodecParameters(rtp_codec_parameters, apt);
                if (associated_codec == null or associated_codec.?.isRtx()) return error.InvalidMedia;
            }
        }
    }

    fn findRtpCodecParameters(rtp_codec_parameters: std.ArrayList(webrtc.RtpCodecParameters), payload_type: u8) ?*webrtc.RtpCodecParameters {
        for (rtp_codec_parameters.items) |*rtp_codec| if (rtp_codec.payload_type == payload_type)
            return rtp_codec;

        return null;
    }

    fn setRtpCodecParameterFmtp(rtp_codec: *webrtc.RtpCodecParameters, fmtp_line: []const u8) !void {
        const codec = if (std.mem.indexOfScalar(u8, rtp_codec.mime_type, '/')) |idx|
            rtp_codec.mime_type[idx + 1 ..]
        else
            rtp_codec.mime_type;
        rtp_codec.fmtp_params = try sdp.Attribute.Fmtp.Params.parse(fmtp_line, codec);
    }
};

pub inline fn getMedias(session: *const SDPSession) []SDPMedia {
    return session.medias.items;
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !SDPSession {
    const session = sdp.Session.parse(data) catch return error.ParseError;
    if (session.version != 0) return error.ParseError;

    var it = session.attributeIterator();
    var result: SDPSession = .empty;

    while (try it.next()) |attr| switch (try attr.parse()) {
        .fingerprint => |fp| switch (fp) {
            .sha_256 => |v| result.fingerprint = v,
            else => return error.ParseError,
        },
        .group => |group| switch (group.semantics) {
            .BUNDLE => result.bundle = group.mids,
            else => {},
        },
        .ice_lite => result.ice_lite = true,
        else => {},
    };

    var medias: std.ArrayList(SDPMedia) = .empty;
    errdefer {
        for (medias.items) |*m| m.deinit(allocator);
        medias.deinit(allocator);
    }

    var media_it = session.mediaIterator();
    while (try media_it.next()) |media| {
        try medias.append(allocator, try .parse(allocator, media, &result.fingerprint));
    }

    for (medias.items) |*media| if (media.port != 0 and result.bundle.len == 0)
        return error.MissingBundleGroup;

    // TODO: check all media have different mid values
    try validateIceCredentials(medias.items);

    result.medias = medias;
    return result;
}

pub fn deinit(s: *SDPSession, allocator: std.mem.Allocator) void {
    for (s.getMedias()) |*m| m.deinit(allocator);
    s.medias.deinit(allocator);
}

pub fn write(s: *const SDPSession, w: *std.Io.Writer) !void {
    var bundle: bool = false;
    for (s.getMedias()) |*m| if (m.port != 0) {
        bundle = true;
        break;
    };

    try w.writeAll(sdp_header);

    if (bundle) {
        try w.writeAll("a=group:BUNDLE");
        for (s.getMedias()) |*m| if (m.port != 0) try w.print(" {s}", .{m.getMid()});
        try w.writeAll("\r\n");
    }

    try SDPAttribute.write(.{ .ice_options = .{ .ice2 = true } }, w);
    try s.writeFingerprint(w);
    for (s.getMedias()) |*m| try m.write(w);
}

pub fn clone(s: *const SDPSession, allocator: std.mem.Allocator) !SDPSession {
    var new_session: SDPSession = .{
        .bundle = &.{},
        .fingerprint = s.fingerprint,
        .ice_lite = s.ice_lite,
        .medias = try .initCapacity(allocator, s.getMedias().len),
    };
    errdefer new_session.deinit(allocator);

    for (s.getMedias()) |*m| {
        const media = try new_session.medias.addOne(allocator);
        media.* = .empty;
        media.* = try m.clone(allocator);
    }

    return new_session;
}

fn writeFingerprint(s: *const SDPSession, w: *std.Io.Writer) !void {
    var attr = SDPAttribute{ .fingerprint = .{ .sha_256 = s.fingerprint } };
    try attr.write(w);
}

fn validateIceCredentials(medias: []SDPMedia) !void {
    if (medias.len == 0) return;
    const ice_ufrag = medias[0].ice_ufrag;
    const ice_pwd = medias[0].ice_pwd;

    if (ice_ufrag.len < 4 or ice_pwd.len < 22) return error.InvalidIceCredentials;
    for (medias[1..]) |*media| {
        if (media.ice_ufrag.len == 0 and media.ice_pwd.len == 0) continue;
        if (!std.mem.eql(u8, media.ice_ufrag, ice_ufrag) or !std.mem.eql(u8, media.ice_pwd, ice_pwd))
            return error.MismatchedCredentials;
    }
}

test {
    _ = @import("tests/sdp_session.zig");
}
