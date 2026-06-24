const std = @import("std");
const SDPSession = @import("../sdp_session.zig");
const rtp = @import("rtp");

const Demuxer = @This();

ssrc_to_mid: std.AutoHashMap(u32, [3]u8),
pt_to_mid: std.AutoHashMap(u8, [3]u8),
mid_id: ?u16 = null,

pub fn init(allocator: std.mem.Allocator) Demuxer {
    return .{
        .pt_to_mid = .init(allocator),
        .ssrc_to_mid = .init(allocator),
    };
}

pub fn deinit(demuxer: *Demuxer) void {
    demuxer.pt_to_mid.deinit();
    demuxer.ssrc_to_mid.deinit();
}

pub fn updateMaps(demuxer: *Demuxer, sdp_session: *const SDPSession) !void {
    for (sdp_session.getMedias()) |*media| {
        inner: for (media.rtp_codec_parameters) |codec| {
            for (sdp_session.getMedias()) |*m| if (!std.mem.eql(u8, media.getMid(), m.getMid()) and m.hasPayload(codec.payload_type))
                continue :inner;

            try demuxer.pt_to_mid.put(codec.payload_type, media.mid);
        }
    }
}

pub fn getMid(demuxer: *Demuxer, packet: *const rtp.Packet) !?[]const u8 {
    if (demuxer.ssrc_to_mid.get(packet.header.ssrc)) |mid| return &mid;

    if (demuxer.mid_id != null) if (getMidFromPacket(packet, demuxer.mid_id.?) catch return null) |mid| {
        var ssrc_mid: [3]u8 = @splat(0);
        @memcpy(ssrc_mid[0..mid.len], mid);
        try demuxer.ssrc_to_mid.put(packet.header.ssrc, ssrc_mid);
        return mid;
    };

    return if (demuxer.pt_to_mid.getPtr(packet.header.payload_type)) |value| value else null;
}

fn getMidFromPacket(packet: *const rtp.Packet, mid_id: u16) !?[]const u8 {
    if (packet.extension) |extension| {
        var it = try rtp.Packet.Extension.Iterator.init(extension);
        while (try it.next()) |item| if (item.id == mid_id) return item.value;
    }

    return null;
}

const RtpCodecParameters = @import("../webrtc.zig").RtpCodecParameters;

fn testSdpSession(alloc: std.mem.Allocator) !SDPSession {
    var medias = try alloc.alloc(SDPSession.SDPMedia, 3);
    for (medias) |*m| m.* = .empty;

    var session: SDPSession = .empty;
    session.medias = .fromOwnedSlice(medias);

    var media1_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[0].rtp_codec_parameters = media1_params;
    medias[0].mid = .{ '1', 0, 0 };
    media1_params[0] = .{ .payload_type = 96, .clock_rate = 90000, .mime_type = "video/h264" };
    media1_params[1] = .{ .payload_type = 97, .clock_rate = 90000, .mime_type = "video/rtx" };
    media1_params[2] = .{ .payload_type = 98, .clock_rate = 90000, .mime_type = "video/vp8" };

    var media2_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[1].rtp_codec_parameters = media2_params;
    medias[1].mid = .{ '2', 0, 0 };
    media2_params[0] = .{ .payload_type = 98, .clock_rate = 90000, .mime_type = "video/h264" };
    media2_params[1] = .{ .payload_type = 99, .clock_rate = 90000, .mime_type = "video/rtx" };
    media2_params[2] = .{ .payload_type = 100, .clock_rate = 90000, .mime_type = "video/vp9" };

    var media3_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[2].rtp_codec_parameters = media3_params;
    medias[2].mid = .{ '3', 0, 0 };
    media3_params[0] = .{ .payload_type = 96, .clock_rate = 90000, .mime_type = "video/h265" };
    media3_params[1] = .{ .payload_type = 105, .clock_rate = 90000, .mime_type = "video/rtx" };
    media3_params[2] = .{ .payload_type = 106, .clock_rate = 90000, .mime_type = "video/av1" };

    return session;
}

test "update maps" {
    var demuxer = init(std.testing.allocator);
    defer demuxer.deinit();

    var session = try testSdpSession(std.testing.allocator);
    defer session.deinit(std.testing.allocator);

    try demuxer.updateMaps(&session);

    try std.testing.expectEqual(5, demuxer.pt_to_mid.count());
    var entry = demuxer.pt_to_mid.get(97);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("1", std.mem.sliceTo(&entry.?, 0));

    entry = demuxer.pt_to_mid.get(99);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("2", std.mem.sliceTo(&entry.?, 0));

    entry = demuxer.pt_to_mid.get(100);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("2", std.mem.sliceTo(&entry.?, 0));

    entry = demuxer.pt_to_mid.get(105);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("3", std.mem.sliceTo(&entry.?, 0));

    entry = demuxer.pt_to_mid.get(106);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("3", std.mem.sliceTo(&entry.?, 0));
}

test "getMid" {
    var demuxer = init(std.testing.allocator);
    defer demuxer.deinit();

    var session = try testSdpSession(std.testing.allocator);
    defer session.deinit(std.testing.allocator);

    try demuxer.updateMaps(&session);

    var packet: rtp.Packet = .{
        .header = .{
            .payload_type = 99,
            .ssrc = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .marker = true,
            .extension = false,
            .padding = false,
        },
        .payload = &.{},
    };
    const mid = try demuxer.getMid(&packet);
    try std.testing.expect(mid != null);

    packet.header.payload_type = 96;
    try std.testing.expect(try demuxer.getMid(&packet) == null);
}
