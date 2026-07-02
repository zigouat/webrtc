pub const PeerConnection = @import("peer_connection.zig");
pub const SDPSession = @import("sdp_session.zig");

const sdp = @import("sdp");
const rtp = @import("rtp");
const rtcp = @import("rtcp");
const utils = @import("utils.zig");
const FmtpParams = sdp.Attribute.Fmtp.Params;

const std = @import("std");
const DtlsTransport = @import("dtls_transport.zig");
const testing = std.testing;

const ntp_unix_epoch_diff = 2_208_988_800;

/// Default video codecs used for sending and receiving video tracks.
///
/// This can be overridden by the user to only include the codecs they want to support.
pub var default_video_codecs: []const RtpCodecParameters = &[_]RtpCodecParameters{
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

/// SignalingState represents the signaling state of the PeerConnection.
pub const SignalingState = enum {
    /// In the stable state there is no offer/answer exchange in progress.
    /// This is also the initial state, in which case the local and remote descriptions are empty.
    stable,
    /// A local description, of type "offer", has been successfully applied.
    have_local_offer,
    /// A remote description, of type "offer", has been successfully applied.
    have_remote_offer,
    /// A remote description of type "offer" has been successfully applied and a local description of
    /// type "pranswer" has been successfully applied.
    have_local_pranswer,
    /// A local description of type "offer" has been successfully applied and a remote description of
    /// type "pranswer" has been successfully applied.
    have_remote_pranswer,
    /// The PeerConnection has been closed.
    closed,
};

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

    pub fn reverse(direction: Direction) Direction {
        return switch (direction) {
            .sendonly => .recvonly,
            .recvonly => .sendonly,
            .inactive, .sendrecv => |d| d,
        };
    }

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

pub const TrackKind = enum { audio, video };

pub const SessionDescriptionType = enum { offer, pranswer, answer, rollback };

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
    id: [64:0]u8,
    kind: TrackKind,
    streams: std.ArrayList([]const u8),
    muted: bool,

    /// Init a new track with generated id.
    ///
    /// Th io instance is needed to generate an id
    pub fn init(io: std.Io, kind: TrackKind) MediaStreamTrack {
        var buf: [16]u8 = undefined;
        io.random(&buf);

        var track: MediaStreamTrack = .{
            .id = @splat(0),
            .kind = kind,
            .streams = .empty,
            .muted = false,
        };

        @memcpy(track.id[0..32], &std.fmt.bytesToHex(buf, .lower));
        return track;
    }

    pub fn deinit(track: *MediaStreamTrack, allocator: std.mem.Allocator) void {
        track.streams.deinit(allocator);
    }

    pub fn initWithId(id: []const u8, kind: TrackKind) MediaStreamTrack {
        std.debug.assert(id.len <= 64);
        var track: MediaStreamTrack = .{
            .id = @splat(0),
            .kind = kind,
            .streams = .empty,
            .muted = false,
        };

        @memcpy(track.id[0..id.len], id);
        return track;
    }

    pub fn getId(track: *const MediaStreamTrack) []const u8 {
        return std.mem.sliceTo(&track.id, 0);
    }

    pub fn clone(track: *const MediaStreamTrack, allocator: std.mem.Allocator) std.mem.Allocator.Error!MediaStreamTrack {
        var new_track = MediaStreamTrack.initWithId(track.getId(), track.kind);
        errdefer new_track.deinit(allocator);

        for (track.streams.items) |stream| {
            const copy = try allocator.dupe(u8, stream);
            errdefer allocator.free(copy);
            try new_track.streams.append(allocator, copy);
        }
        return new_track;
    }

    fn addStream(track: *MediaStreamTrack, allocator: std.mem.Allocator, stream: MediaStream) !void {
        try track.streams.append(allocator, stream.id);
    }

    test "init" {
        const track = init(std.testing.io, .video);
        try std.testing.expect(!std.mem.eql(u8, &.{}, track.getId()));
    }

    test "getId" {
        const track = initWithId("test-track", .audio);
        try std.testing.expectEqualStrings("test-track", track.getId());
    }
};

pub const TrackEventInit = struct {
    receiver: *RtpReceiver,
    track: MediaStreamTrack,
    transceiver: *RtpTransceiver,
};

pub const RtpSender = struct {
    track: ?MediaStreamTrack,
    codecs: []const RtpCodecParameters,
    ssrc: u32,
    report: Report,

    const Report = struct {
        last_sequence_number: ?u16,
        rtp_timestamp: u32,
        timestamp: i64,
        packet_count: u32,
        octet_count: u32,

        const empty: Report = .{
            .last_sequence_number = null,
            .rtp_timestamp = 0,
            .timestamp = 0,
            .packet_count = 0,
            .octet_count = 0,
        };

        inline fn recordPacket(report: *Report, packet: *const rtp.Packet, timestamp: i64) void {
            const last_seq_number = report.last_sequence_number orelse packet.header.sequence_number -% 1;
            const diff = @as(i16, @bitCast(packet.header.sequence_number)) -% @as(i16, @bitCast(last_seq_number));

            // check for out of order packets
            if (diff > 0) {
                report.last_sequence_number = packet.header.sequence_number;
                report.rtp_timestamp = packet.header.timestamp;
                report.timestamp = timestamp;
            }

            report.packet_count += 1;
            report.octet_count += @intCast(packet.payload.len);
        }
    };

    pub fn init(track: ?MediaStreamTrack) RtpSender {
        return .{
            .track = track,
            .codecs = &.{},
            .ssrc = 0,
            .report = .empty,
        };
    }

    pub fn getCapabilities(kind: TrackKind) RtpCapabilities {
        _ = kind;
        return .{ .codecs = &.{}, .header_extensions = &.{} };
    }

    pub fn replaceTrack(sender: *RtpSender, new_track: MediaStreamTrack) !void {
        _ = sender;
        _ = new_track;
        @panic("Not Implemented");
    }

    pub fn addStream(sender: *RtpSender, allocator: std.mem.Allocator, stream: MediaStream) !void {
        if (sender.track == null) return;
        const track = &sender.track.?;
        try track.addStream(allocator, stream);
    }

    pub fn sendRtp(sender: *RtpSender, packet: *const rtp.Packet) !void {
        if (sender.track == null) {
            @branchHint(.cold);
            return error.NoAssociatedTrack;
        }

        const tr: *RtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
        if (!tr.canSend()) {
            @branchHint(.unlikely);
            return error.InvalidDirection;
        }

        var buffer = try tr.transport.ice_agent.createPacket();
        defer tr.transport.ice_agent.destroyPacket(buffer);

        const timestamp = std.Io.Timestamp.now(tr.transport.getIo(), .real).toMicroseconds();

        const header: rtp.Packet.Header = .{
            .extension = false,
            .marker = packet.header.marker,
            .padding = false,
            .payload_type = @intCast(tr.sender.codecs[0].payload_type),
            .sequence_number = packet.header.sequence_number,
            .ssrc = sender.ssrc,
            .timestamp = packet.header.timestamp,
        };

        std.mem.writeInt(u96, buffer[0..12], @bitCast(header), .big);
        @memcpy(buffer[12 .. packet.payload.len + 12], packet.payload);
        try tr.transport.sendRtp(buffer[0 .. packet.payload.len + 12]);
        sender.report.recordPacket(packet, timestamp);
    }

    fn writeReport(sender: *const RtpSender, timestamp: i64, buffer: []u8) []const u8 {
        if (sender.report.packet_count == 0) return &.{};
        std.debug.assert(buffer.len >= rtcp.header_size + rtcp.sr_base_size);
        const length = rtcp.header_size + rtcp.sr_base_size;

        const header: rtcp.Header = .{
            .payload_type = .sender_report,
            .rc = 0,
            .length = length / 4 - 1,
            .padding = false,
        };
        std.mem.writeInt(@Int(.unsigned, @bitSizeOf(rtcp.Header)), buffer[0..rtcp.header_size], @bitCast(header), .big);

        const report = sender.report;
        const codec = sender.codecs[0]; // First codec is used for sending
        const ts = if (timestamp <= report.timestamp) report.timestamp else timestamp;
        const diff: u32 = @intCast(@divTrunc((ts - report.timestamp) * codec.clock_rate, std.time.us_per_s));

        const sender_report: rtcp.SenderReport = .{
            .ssrc = sender.ssrc,
            .ntp_timestamp = microsecondsToNtp(timestamp),
            .rtp_timestamp = report.rtp_timestamp + diff,
            .octet_count = report.octet_count,
            .packet_count = report.packet_count,
        };
        sender_report.write(buffer[rtcp.header_size..][0..rtcp.sr_base_size]);

        return buffer[0..length];
    }

    fn microsecondsToNtp(timestamp: i64) u64 {
        const ntp_seconds = @divTrunc(timestamp, std.time.us_per_s) + ntp_unix_epoch_diff;
        const ntp_fraction = @rem(timestamp, std.time.us_per_s);
        return @bitCast((ntp_seconds << 32) | ntp_fraction);
    }

    test "record packets" {
        var report: Report = .empty;
        const payload = "hello";
        var packet: rtp.Packet = .{
            .header = .{
                .ssrc = 0,
                .timestamp = 1000,
                .sequence_number = 10,
                .payload_type = 96,
                .marker = false,
                .extension = false,
                .padding = false,
            },
            .payload = payload,
        };

        report.recordPacket(&packet, 5000);

        try std.testing.expectEqual(10, report.last_sequence_number);
        try std.testing.expectEqual(1000, report.rtp_timestamp);
        try std.testing.expectEqual(5000, report.timestamp);
        try std.testing.expectEqual(1, report.packet_count);
        try std.testing.expectEqual(payload.len, report.octet_count);

        packet.header.timestamp = 2000;
        packet.header.sequence_number = 11;

        report.recordPacket(&packet, 6000);
        try std.testing.expectEqual(11, report.last_sequence_number);
        try std.testing.expectEqual(2000, report.rtp_timestamp);
        try std.testing.expectEqual(6000, report.timestamp);
        try std.testing.expectEqual(2, report.packet_count);
        try std.testing.expectEqual(payload.len * 2, report.octet_count);

        packet.header.timestamp = 1500;
        packet.header.sequence_number = 9;

        report.recordPacket(&packet, 7000);

        try std.testing.expectEqual(11, report.last_sequence_number);
        try std.testing.expectEqual(2000, report.rtp_timestamp);
        try std.testing.expectEqual(6000, report.timestamp);
        try std.testing.expectEqual(3, report.packet_count);
        try std.testing.expectEqual(payload.len * 3, report.octet_count);
    }

    test "convert microseconds to ntp" {
        {
            const ntp = microsecondsToNtp(1782228674132465);
            try std.testing.expectEqual(0xEDE52542, ntp >> 32);
            try std.testing.expectEqual(132465, ntp & std.math.maxInt(u32));
        }
        {
            const ntp = microsecondsToNtp(1782228863900100);
            try std.testing.expectEqual(0xEDE525FF, ntp >> 32);
            try std.testing.expectEqual(900100, ntp & std.math.maxInt(u32));
        }
    }
};

pub const RtpReceiver = struct {
    track: MediaStreamTrack,
    codecs: []const RtpCodecParameters = &.{},

    pub fn init(track: MediaStreamTrack) RtpReceiver {
        return .{ .track = track };
    }

    pub fn getCapabilities(kind: TrackKind) RtpCapabilities {
        _ = kind;
        return .{ .codecs = &.{}, .header_extensions = &.{} };
    }

    pub fn handleRtpPacket(receiver: *RtpReceiver, packet: rtp.Packet) !?rtp.Packet {
        _ = receiver;
        return packet;
    }

    fn processMsids(receiver: *RtpReceiver, allocator: std.mem.Allocator, msids: []MediaStream) !void {
        receiver.track.streams.clearAndFree(allocator);
        for (msids) |msid| try receiver.track.addStream(allocator, msid);
    }
};

pub const TransceiverInit = struct {
    direction: Direction,
    streams: []const []const u8 = &.{},
};

pub const RtpTransceiver = struct {
    sender: RtpSender,
    receiver: RtpReceiver,
    kind: TrackKind,
    direction: Direction,
    current_direction: ?Direction = null,
    fired_direction: ?Direction = null,
    mid: ?[]const u8 = null,
    sdp_mline_index: ?u8 = null,
    stopping: bool = false,
    stopped: bool = false,
    added_by_add_track: bool = false,
    transport: *DtlsTransport,

    pub fn initFromSdpMedia(
        allocator: std.mem.Allocator,
        io: std.Io,
        sdp_media: *const SDPSession.SDPMedia,
        index: u8,
    ) !*RtpTransceiver {
        const tr = try allocator.create(RtpTransceiver);
        const track = if (sdp_media.track_id) |track_id|
            MediaStreamTrack.initWithId(track_id, sdp_media.kind)
        else
            MediaStreamTrack.init(io, sdp_media.kind);

        tr.* = .{
            .direction = .recvonly,
            .kind = sdp_media.kind,
            .receiver = .init(track),
            .sender = .init(null),
            .mid = &sdp_media.mid,
            .sdp_mline_index = index,
            .transport = undefined,
        };

        return tr;
    }

    pub fn deinit(tr: *RtpTransceiver, allocator: std.mem.Allocator) void {
        if (tr.sender.track) |*track| track.deinit(allocator);
        tr.receiver.track.deinit(allocator);
        allocator.destroy(tr);
    }

    pub fn toSdpMedia(tr: *RtpTransceiver, allocator: std.mem.Allocator) !SDPSession.SDPMedia {
        var media: SDPSession.SDPMedia = .empty;

        media.kind = tr.kind;
        media.port = if (tr.stopping) 0 else 9;
        media.direction = tr.direction;
        media.rtp_codec_parameters = try allocator.dupe(RtpCodecParameters, getCodecCapabilities(tr.kind));
        media.rtcp_mux = true;
        media.rtcp_rsize = false;
        media.setIceCredentials(tr.transport.ice_agent.credentials);

        try tr.addSenderFields(allocator, &media);
        if (tr.mid) |mid| @memcpy(media.mid[0..mid.len], mid);

        return media;
    }

    pub fn toSdpMediaAnswer(tr: *const RtpTransceiver, allocator: std.mem.Allocator, media: *const SDPSession.SDPMedia) !SDPSession.SDPMedia {
        var answer: SDPSession.SDPMedia = .empty;
        errdefer answer.deinit(allocator);

        const codecs = try utils.getCodecIntersection(
            allocator,
            media.rtp_codec_parameters,
            getCodecCapabilities(tr.kind),
        );
        answer.kind = tr.kind;
        answer.port = if (codecs.len == 0) 0 else 9;
        answer.rtcp_mux = true;
        answer.rtcp_rsize = false;
        answer.setup = switch (media.setup) {
            .active => .passive,
            else => .active,
        };
        answer.direction = media.direction.reverse().intersect(tr.direction);
        answer.rtp_codec_parameters = if (answer.port == 0)
            try allocator.dupe(RtpCodecParameters, media.rtp_codec_parameters)
        else
            codecs;
        @memcpy(answer.mid[0..tr.mid.?.len], tr.mid.?);
        answer.setIceCredentials(tr.transport.ice_agent.credentials);

        if (codecs.len != 0) try tr.addSenderFields(allocator, &answer);
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

    pub fn canAssociateMedia(tr: *const RtpTransceiver, media: *const SDPSession.SDPMedia) bool {
        return (media.direction == .sendrecv or media.direction == .recvonly) and
            tr.kind == media.kind and
            tr.mid == null and
            !tr.stopped;
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
    pub fn removeTrack(tr: *RtpTransceiver, allocator: std.mem.Allocator) void {
        if (tr.stopping or tr.sender.track == null) return;

        tr.sender.track.?.deinit(allocator);
        tr.sender.track = null;

        switch (tr.direction) {
            .sendrecv => tr.direction = .recvonly,
            .sendonly => tr.direction = .inactive,
            else => {},
        }
    }

    pub inline fn canSend(tr: *const RtpTransceiver) bool {
        if (tr.isStopped()) return false;
        if (tr.current_direction) |direction| return direction == .sendrecv or direction == .sendonly;
        return false;
    }

    pub fn processRemoteTrack(
        tr: *RtpTransceiver,
        allocator: std.mem.Allocator,
        direction: Direction,
        msids: []MediaStream,
    ) !?TrackEventInit {
        try tr.receiver.processMsids(allocator, msids);

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
                media.msids = try allocator.alloc(MediaStream, track.streams.items.len);
                errdefer allocator.free(media.msids);

                for (media.msids, track.streams.items) |*msid, stream_id| {
                    msid.* = .{ .id = stream_id };
                }
                media.track_id = try allocator.dupe(u8, track.getId());
                media.ssrc = tr.sender.ssrc;
            },
            else => {},
        }
    }

    fn newTestRtpTransceiver(io: std.Io) RtpTransceiver {
        return .{
            .sender = .init(null),
            .receiver = .{ .track = .init(io, .video) },
            .direction = .sendrecv,
            .kind = .video,
            .transport = undefined,
        };
    }

    test "canAssocaiteTrack" {
        var tr: RtpTransceiver = newTestRtpTransceiver(std.testing.io);
        tr.direction = .recvonly;

        try std.testing.expect(tr.canAssociateTrack(.video));

        tr.kind = .audio;
        try std.testing.expect(!tr.canAssociateTrack(.video));

        tr.kind = .video;
        tr.sender.track = .init(std.testing.io, .video);
        try std.testing.expect(!tr.canAssociateTrack(.video));

        tr.sender.track = null;
        tr.stopping = true;
        try std.testing.expect(!tr.canAssociateTrack(.video));
    }

    test "getRtcpReport" {
        var tr: RtpTransceiver = newTestRtpTransceiver(std.testing.io);
        tr.sender.codecs = getCodecCapabilities(.video);
        var buffer: [64]u8 = @splat(0);

        tr.sender.report = .{
            .last_sequence_number = 0,
            .rtp_timestamp = 8700,
            .timestamp = 1782239529800000,
            .octet_count = 10000,
            .packet_count = 100,
        };

        const data = tr.getRtcpReport(1782239530300000, &buffer);
        const packet = try rtcp.Packet.parse(data);
        try std.testing.expectEqual(.sender_report, packet.header.payload_type);
        try std.testing.expectEqual(tr.sender.ssrc, packet.payload.sender_report.ssrc);
        try std.testing.expectEqual(53700, packet.payload.sender_report.rtp_timestamp);
        try std.testing.expectEqual(17142195148218995680, packet.payload.sender_report.ntp_timestamp);
        try std.testing.expectEqual(10000, packet.payload.sender_report.octet_count);
        try std.testing.expectEqual(100, packet.payload.sender_report.packet_count);
    }

    test "processRemoteTrack" {
        const allocator = std.testing.allocator;
        var tr = newTestRtpTransceiver(std.testing.io);

        var maybe_event = try tr.processRemoteTrack(allocator, .sendrecv, &.{});
        try std.testing.expect(maybe_event != null);
        try std.testing.expect(maybe_event.?.transceiver == &tr);
        try std.testing.expect(tr.fired_direction == .sendrecv);

        maybe_event = try tr.processRemoteTrack(allocator, .recvonly, &.{});
        try std.testing.expect(maybe_event == null);

        maybe_event = try tr.processRemoteTrack(allocator, .inactive, &.{});
        try std.testing.expect(maybe_event == null);
        try std.testing.expect(tr.receiver.track.muted);

        maybe_event = try tr.processRemoteTrack(allocator, .recvonly, &.{});
        try std.testing.expect(maybe_event != null);
    }
};

pub fn getCodecCapabilities(kind: TrackKind) []const RtpCodecParameters {
    return switch (kind) {
        .audio => &.{},
        .video => default_video_codecs,
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("peer_connection.zig");
    _ = @import("sdp_session.zig");
}
