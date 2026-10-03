const std = @import("std");
const SDPSession = @import("../sdp_session.zig");
const rtp = @import("rtp");
const Mid = @import("../mid.zig");
const webrtc = @import("../webrtc.zig");
const RtpTransceiver = @import("../rtp_transceiver.zig");

const Demuxer = @This();

const max_entries = 1000;

pub const Lookup = union(enum) {
    transceiver: u32,
    mid: Mid.Int,
    none,
};

generated_ssrc: std.AutoHashMap(u32, void),
ssrc_to_transceiver: std.AutoHashMap(u32, u32),
pt_to_transceiver: std.AutoHashMap(u8, u32),
mid_id: ?u16 = null,

pub fn init(allocator: std.mem.Allocator) Demuxer {
    return .{
        .generated_ssrc = .init(allocator),
        .pt_to_transceiver = .init(allocator),
        .ssrc_to_transceiver = .init(allocator),
    };
}

pub fn deinit(demuxer: *Demuxer) void {
    demuxer.generated_ssrc.deinit();
    demuxer.pt_to_transceiver.deinit();
    demuxer.ssrc_to_transceiver.deinit();
}

pub fn updateMaps(demuxer: *Demuxer, sdp_session: *const SDPSession, transceivers: []const RtpTransceiver) !void {
    for (sdp_session.getMedias()) |*media| {
        if (demuxer.mid_id == null) for (media.rtp_header_extensions) |ext| if (std.mem.eql(u8, ext.uri, webrtc.mid_extension_uri)) {
            demuxer.mid_id = ext.id;
        };

        const tr_id = findTransceiverByMid(transceivers, media.mid) orelse continue;

        if (media.ssrc) |ssrc| try demuxer.addEntry(ssrc, tr_id);
        if (media.rtx_ssrc) |ssrc| try demuxer.addEntry(ssrc, tr_id);

        inner: for (media.rtp_codec_parameters) |codec| {
            for (sdp_session.getMedias()) |*m| if (media.mid != m.mid and m.hasPayload(codec.payload_type))
                continue :inner;

            try demuxer.pt_to_transceiver.put(codec.payload_type, tr_id);
        }
    }
}

pub fn getTransceiver(demuxer: *Demuxer, packet: *const rtp.Packet) Lookup {
    if (demuxer.ssrc_to_transceiver.get(packet.header.ssrc)) |tr_id| {
        @branchHint(.likely);
        return .{ .transceiver = tr_id };
    }

    if (demuxer.mid_id != null) if (getMidFromPacket(packet, demuxer.mid_id.?) catch return .none) |mid| {
        if (mid.len <= 3) return .{ .mid = Mid.fromBytes(mid) catch unreachable };
    };

    if (demuxer.pt_to_transceiver.get(packet.header.payload_type)) |tr_id| return .{ .transceiver = tr_id };
    return .none;
}

pub fn cacheSsrc(demuxer: *Demuxer, ssrc: u32, tr_id: u32) !void {
    try demuxer.addEntry(ssrc, tr_id);
}

pub fn registerRandomSsrc(demuxer: *Demuxer, random: std.Random) !u32 {
    var ssrc: u32 = 0;
    while (true) {
        ssrc = random.int(u32);
        if (demuxer.generated_ssrc.contains(ssrc)) continue;
        try demuxer.generated_ssrc.put(ssrc, {});
        return ssrc;
    }
}

fn getMidFromPacket(packet: *const rtp.Packet, mid_id: u16) !?[]const u8 {
    if (packet.extension) |extension| {
        var it = try rtp.Packet.Extension.Iterator.init(extension);
        while (try it.next()) |item| if (item.id == mid_id) return item.value;
    }

    return null;
}

fn findTransceiverByMid(transceivers: []const RtpTransceiver, mid: Mid.Int) ?u32 {
    for (transceivers, 0..) |*tr, idx| if (tr.mid) |tr_mid| if (tr_mid == mid) return @intCast(idx);
    return null;
}

fn addEntry(demuxer: *Demuxer, ssrc: u32, tr_id: u32) !void {
    if (demuxer.ssrc_to_transceiver.count() >= max_entries) return error.TooManyEntries;
    try demuxer.ssrc_to_transceiver.put(ssrc, tr_id);
    try demuxer.generated_ssrc.put(ssrc, {});
}

const RtpCodecParameters = @import("../webrtc.zig").RtpCodecParameters;

// MID strings packed into a u24 the same way SDP parsing does (mid[0] in the low byte).
const mid_ext_id = 4;
const mid_1: u24 = @bitCast([3]u8{ '1', 0, 0 });
const mid_2: u24 = @bitCast([3]u8{ '2', 0, 0 });
const mid_3: u24 = @bitCast([3]u8{ '3', 0, 0 });

fn testSdpSession(alloc: std.mem.Allocator) !SDPSession {
    var medias = try alloc.alloc(SDPSession.Media, 3);
    for (medias) |*m| m.* = .empty;

    var session: SDPSession = .empty;
    session.medias = .fromOwnedSlice(medias);

    var media1_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[0].rtp_codec_parameters = media1_params;
    medias[0].mid = mid_1;
    medias[0].ssrc = 0x10101010;
    medias[0].rtx_ssrc = 0x30303030;
    media1_params[0] = .{ .payload_type = 96, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/h264" } };
    media1_params[1] = .{ .payload_type = 97, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/rtx" } };
    media1_params[2] = .{ .payload_type = 98, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/vp8" } };

    medias[0].rtp_header_extensions = try alloc.dupe(webrtc.RtpHeaderExtensionParameter, &.{
        .{ .id = mid_ext_id, .uri = webrtc.mid_extension_uri },
    });

    var media2_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[1].rtp_codec_parameters = media2_params;
    medias[1].mid = mid_2;
    media2_params[0] = .{ .payload_type = 98, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/h264" } };
    media2_params[1] = .{ .payload_type = 99, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/rtx" } };
    media2_params[2] = .{ .payload_type = 100, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/vp9" } };

    var media3_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[2].rtp_codec_parameters = media3_params;
    medias[2].mid = mid_3;
    medias[2].ssrc = 0x20202020;
    media3_params[0] = .{ .payload_type = 96, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/h265" } };
    media3_params[1] = .{ .payload_type = 105, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/rtx" } };
    media3_params[2] = .{ .payload_type = 106, .rtp_codec = .{ .clock_rate = 90000, .mime_type = "video/av1" } };

    return session;
}

fn testPacket(ssrc: u32) rtp.Packet {
    return .{
        .header = .{
            .payload_type = 99,
            .ssrc = ssrc,
            .sequence_number = 0,
            .timestamp = 0,
            .marker = true,
            .extension = false,
            .padding = false,
        },
        .payload = &.{},
    };
}

fn testTransceiver(mid: Mid.Int) RtpTransceiver {
    return .{
        .sender = .init(null),
        .receiver = .init(.initWithId("track", .video)),
        .kind = .video,
        .direction = .sendrecv,
        .mid = mid,
        .pc = undefined,
    };
}

test "Demuxer.updateMaps" {
    const allocator = std.testing.allocator;

    var demuxer = init(allocator);
    defer demuxer.deinit();

    var session = try testSdpSession(allocator);
    defer session.deinit(allocator);

    const tr1 = testTransceiver(mid_1);
    const tr2 = testTransceiver(mid_2);
    const tr3 = testTransceiver(mid_3);
    const transceivers = [_]RtpTransceiver{ tr1, tr2, tr3 };

    try demuxer.updateMaps(&session, &transceivers);

    try std.testing.expectEqual(mid_ext_id, demuxer.mid_id.?);

    try std.testing.expectEqual(3, demuxer.ssrc_to_transceiver.count());
    try std.testing.expectEqual(@as(u32, 0), demuxer.ssrc_to_transceiver.get(0x10101010).?);
    try std.testing.expectEqual(@as(u32, 0), demuxer.ssrc_to_transceiver.get(0x30303030).?);
    try std.testing.expectEqual(@as(u32, 2), demuxer.ssrc_to_transceiver.get(0x20202020).?);

    try std.testing.expectEqual(5, demuxer.pt_to_transceiver.count());
    var entry = demuxer.pt_to_transceiver.get(97);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 0), entry.?);

    entry = demuxer.pt_to_transceiver.get(99);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 1), entry.?);

    entry = demuxer.pt_to_transceiver.get(100);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 1), entry.?);

    entry = demuxer.pt_to_transceiver.get(105);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 2), entry.?);

    entry = demuxer.pt_to_transceiver.get(106);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 2), entry.?);
}

test "Demuxer.getTransceiver" {
    const allocator = std.testing.allocator;

    var demuxer = init(allocator);
    defer demuxer.deinit();

    var session = try testSdpSession(allocator);
    defer session.deinit(allocator);

    const tr1 = testTransceiver(mid_1);
    const tr2 = testTransceiver(mid_2);
    const tr3 = testTransceiver(mid_3);
    const transceivers = [_]RtpTransceiver{ tr1, tr2, tr3 };

    try demuxer.updateMaps(&session, &transceivers);

    var packet = testPacket(0);
    var lookup = demuxer.getTransceiver(&packet);
    try std.testing.expectEqual(.transceiver, std.meta.activeTag(lookup));
    try std.testing.expectEqual(@as(u32, 1), lookup.transceiver);

    packet.header.payload_type = 96;
    lookup = demuxer.getTransceiver(&packet);
    try std.testing.expectEqual(.none, std.meta.activeTag(lookup));

    packet.header.ssrc = 0x10101010;
    packet.header.payload_type = 10;
    lookup = demuxer.getTransceiver(&packet);
    try std.testing.expectEqual(.transceiver, std.meta.activeTag(lookup));
    try std.testing.expectEqual(@as(u32, 0), lookup.transceiver);
}

test "Demuxer.registerRandomSsrc: returns unique ssrcs and tracks them" {
    var demuxer = init(std.testing.allocator);
    defer demuxer.deinit();

    var prng: std.Random.DefaultPrng = .init(0);
    const random = prng.random();

    const first = try demuxer.registerRandomSsrc(random);
    const second = try demuxer.registerRandomSsrc(random);

    try std.testing.expect(first != second);
    try std.testing.expect(demuxer.generated_ssrc.contains(first));
    try std.testing.expect(demuxer.generated_ssrc.contains(second));
    try std.testing.expectEqual(2, demuxer.generated_ssrc.count());
}

test "Demuxer.getTransceiver: falls back to the mid header extension when ssrc is unknown" {
    const allocator = std.testing.allocator;

    var demuxer = init(allocator);
    defer demuxer.deinit();

    var session = try testSdpSession(allocator);
    defer session.deinit(allocator);

    const tr1 = testTransceiver(mid_1);
    const tr2 = testTransceiver(mid_2);
    const tr3 = testTransceiver(mid_3);
    const transceivers = [_]RtpTransceiver{ tr1, tr2, tr3 };

    try demuxer.updateMaps(&session, &transceivers);
    try std.testing.expectEqual(mid_ext_id, demuxer.mid_id.?);

    var ext_buffer: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&ext_buffer);
    var ext_writer = try rtp.Packet.Extension.Writer.init(.one_byte, &w);
    try ext_writer.writeItem(.{ .id = mid_ext_id, .value = "1" });
    try ext_writer.flush();

    const packet: rtp.Packet = .{
        .header = .{
            .payload_type = 50,
            .ssrc = 0xDEADBEEF,
            .sequence_number = 0,
            .timestamp = 0,
            .marker = false,
            .extension = true,
            .padding = false,
        },
        .extension = .{ .profile = .one_byte, .data = w.buffered()[4..] },
        .payload = &.{},
    };

    var lookup = demuxer.getTransceiver(&packet);
    try std.testing.expectEqual(.mid, std.meta.activeTag(lookup));
    try std.testing.expectEqual(mid_1, lookup.mid);

    try std.testing.expect(!demuxer.ssrc_to_transceiver.contains(packet.header.ssrc));

    try demuxer.cacheSsrc(packet.header.ssrc, 0);
    try std.testing.expect(demuxer.ssrc_to_transceiver.contains(packet.header.ssrc));

    lookup = demuxer.getTransceiver(&packet);
    try std.testing.expectEqual(.transceiver, std.meta.activeTag(lookup));
    try std.testing.expectEqual(@as(u32, 0), lookup.transceiver);
}

test "Demuxer.getTransceiver: returs error when count entries exceeds max_entries" {
    const allocator = std.testing.allocator;

    var demuxer = init(allocator);
    demuxer.mid_id = mid_ext_id;
    defer demuxer.deinit();

    var packet = testPacket(0xBEBEBEBE);
    packet.extension = .{ .profile = .one_byte, .data = &.{ 0x40, '1', 0, 0 } };

    var ssrc: u32 = 0xBEBEBEBE;
    for (0..max_entries) |_| {
        try demuxer.cacheSsrc(packet.header.ssrc, 0);
        ssrc += 1;
        packet.header.ssrc = ssrc;
    }

    try std.testing.expectEqual(mid_1, demuxer.getTransceiver(&packet).mid);
    try std.testing.expectError(error.TooManyEntries, demuxer.cacheSsrc(packet.header.ssrc, 0));
}
