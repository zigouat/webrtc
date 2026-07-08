const std = @import("std");
const SDPSession = @import("../sdp_session.zig");
const rtp = @import("rtp");

const Demuxer = @This();

ssrc_to_mid: std.AutoHashMap(u32, [3]u8),
pt_to_mid: std.AutoHashMap(u8, [3]u8),
mid_id: ?u16 = null,
mutex: std.Io.Mutex = .init,

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

pub fn updateMaps(demuxer: *Demuxer, io: std.Io, sdp_session: *const SDPSession) !void {
    try demuxer.mutex.lock(io);
    defer demuxer.mutex.unlock(io);

    for (sdp_session.getMedias()) |*media| {
        if (media.ssrc) |ssrc| {
            try demuxer.ssrc_to_mid.put(ssrc, media.mid);
        }

        inner: for (media.rtp_codec_parameters) |codec| {
            for (sdp_session.getMedias()) |*m| if (!std.mem.eql(u8, media.getMid(), m.getMid()) and m.hasPayload(codec.payload_type))
                continue :inner;

            try demuxer.pt_to_mid.put(codec.payload_type, media.mid);
        }
    }
}

pub fn getMid(demuxer: *Demuxer, io: std.Io, packet: *const rtp.Packet) !?[]const u8 {
    try demuxer.mutex.lock(io);
    defer demuxer.mutex.unlock(io);

    if (demuxer.ssrc_to_mid.getPtr(packet.header.ssrc)) |mid| {
        @branchHint(.likely);
        return std.mem.sliceTo(mid, 0);
    }

    if (demuxer.mid_id != null) if (getMidFromPacket(packet, demuxer.mid_id.?) catch return null) |mid| {
        var ssrc_mid: [3]u8 = @splat(0);
        @memcpy(ssrc_mid[0..mid.len], mid);
        try demuxer.ssrc_to_mid.put(packet.header.ssrc, ssrc_mid);
        return mid;
    };

    return if (demuxer.pt_to_mid.getPtr(packet.header.payload_type)) |value| std.mem.sliceTo(value, 0) else null;
}

pub fn containsSsrc(demuxer: *Demuxer, io: std.Io, ssrc: u32) bool {
    demuxer.mutex.lockUncancelable(io);
    defer demuxer.mutex.unlock(io);

    return demuxer.ssrc_to_mid.contains(ssrc);
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
    medias[0].ssrc = 0x10101010;
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
    medias[2].ssrc = 0x20202020;
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

    try demuxer.updateMaps(std.testing.io, &session);

    try std.testing.expectEqual(2, demuxer.ssrc_to_mid.count());
    try std.testing.expectEqualStrings("1\x00\x00", &demuxer.ssrc_to_mid.get(0x10101010).?);
    try std.testing.expectEqualStrings("3\x00\x00", &demuxer.ssrc_to_mid.get(0x20202020).?);

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
    const io = std.testing.io;

    var demuxer = init(std.testing.allocator);
    defer demuxer.deinit();

    var session = try testSdpSession(std.testing.allocator);
    defer session.deinit(std.testing.allocator);

    try demuxer.updateMaps(io, &session);

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
    const mid = try demuxer.getMid(io, &packet);
    try std.testing.expect(mid != null);

    packet.header.payload_type = 96;
    try std.testing.expect(try demuxer.getMid(io, &packet) == null);

    packet.header.ssrc = 0x10101010;
    packet.header.payload_type = 10;
    try std.testing.expect(try demuxer.getMid(io, &packet) != null);
}
