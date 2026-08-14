const std = @import("std");
const SDPSession = @import("../sdp_session.zig");
const rtp = @import("rtp");
const Mid = @import("../mid.zig");
const webrtc = @import("../webrtc.zig");

const Demuxer = @This();

generated_ssrc: std.AutoHashMap(u32, void),
ssrc_to_mid: std.AutoHashMap(u32, Mid.Int),
pt_to_mid: std.AutoHashMap(u8, Mid.Int),
mid_id: ?u16 = null,
mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator) Demuxer {
    return .{
        .generated_ssrc = .init(allocator),
        .pt_to_mid = .init(allocator),
        .ssrc_to_mid = .init(allocator),
    };
}

pub fn deinit(demuxer: *Demuxer) void {
    demuxer.generated_ssrc.deinit();
    demuxer.pt_to_mid.deinit();
    demuxer.ssrc_to_mid.deinit();
}

pub fn updateMaps(demuxer: *Demuxer, io: std.Io, sdp_session: *const SDPSession) !void {
    try demuxer.mutex.lock(io);
    defer demuxer.mutex.unlock(io);

    for (sdp_session.getMedias()) |*media| {
        if (media.ssrc) |ssrc| {
            try demuxer.ssrc_to_mid.put(ssrc, media.mid);
            try demuxer.generated_ssrc.put(ssrc, {});
        }

        if (media.rtx_ssrc) |ssrc| {
            try demuxer.ssrc_to_mid.put(ssrc, media.mid);
            try demuxer.generated_ssrc.put(ssrc, {});
        }

        if (demuxer.mid_id == null) for (media.rtp_header_extensions) |ext| if (std.mem.eql(u8, ext.uri, webrtc.mid_extension_uri)) {
            demuxer.mid_id = ext.id;
        };

        inner: for (media.rtp_codec_parameters) |codec| {
            for (sdp_session.getMedias()) |*m| if (media.mid != m.mid and m.hasPayload(codec.payload_type))
                continue :inner;

            try demuxer.pt_to_mid.put(codec.payload_type, media.mid);
        }
    }
}

pub fn getMid(demuxer: *Demuxer, io: std.Io, packet: *const rtp.Packet) !?Mid.Int {
    try demuxer.mutex.lock(io);
    defer demuxer.mutex.unlock(io);

    if (demuxer.ssrc_to_mid.get(packet.header.ssrc)) |mid| {
        @branchHint(.likely);
        return mid;
    }

    if (demuxer.mid_id != null) if (getMidFromPacket(packet, demuxer.mid_id.?) catch return null) |mid| {
        if (mid.len <= 3) {
            const packed_mid = Mid.fromBytes(mid) catch unreachable;
            try demuxer.ssrc_to_mid.put(packet.header.ssrc, packed_mid);
            return packed_mid;
        }
    };

    return if (demuxer.pt_to_mid.get(packet.header.payload_type)) |value| value else null;
}

pub fn registerRandomSsrc(demuxer: *Demuxer, io: std.Io) !u32 {
    demuxer.mutex.lockUncancelable(io);
    defer demuxer.mutex.unlock(io);

    var ssrc: u32 = 0;
    while (true) {
        io.random(std.mem.asBytes(&ssrc));
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
    media1_params[0] = .{ .payload_type = 96, .clock_rate = 90000, .mime_type = "video/h264" };
    media1_params[1] = .{ .payload_type = 97, .clock_rate = 90000, .mime_type = "video/rtx" };
    media1_params[2] = .{ .payload_type = 98, .clock_rate = 90000, .mime_type = "video/vp8" };

    medias[0].rtp_header_extensions = try alloc.dupe(webrtc.RtpHeaderExtensionParameter, &.{
        .{ .id = mid_ext_id, .uri = webrtc.mid_extension_uri },
    });

    var media2_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[1].rtp_codec_parameters = media2_params;
    medias[1].mid = mid_2;
    media2_params[0] = .{ .payload_type = 98, .clock_rate = 90000, .mime_type = "video/h264" };
    media2_params[1] = .{ .payload_type = 99, .clock_rate = 90000, .mime_type = "video/rtx" };
    media2_params[2] = .{ .payload_type = 100, .clock_rate = 90000, .mime_type = "video/vp9" };

    var media3_params = try alloc.alloc(RtpCodecParameters, 3);
    medias[2].rtp_codec_parameters = media3_params;
    medias[2].mid = mid_3;
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

    try std.testing.expectEqual(mid_ext_id, demuxer.mid_id.?);

    try std.testing.expectEqual(3, demuxer.ssrc_to_mid.count());
    try std.testing.expectEqual(mid_1, demuxer.ssrc_to_mid.get(0x10101010).?);
    try std.testing.expectEqual(mid_1, demuxer.ssrc_to_mid.get(0x30303030).?);
    try std.testing.expectEqual(mid_3, demuxer.ssrc_to_mid.get(0x20202020).?);

    try std.testing.expectEqual(5, demuxer.pt_to_mid.count());
    var entry = demuxer.pt_to_mid.get(97);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(mid_1, entry.?);

    entry = demuxer.pt_to_mid.get(99);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(mid_2, entry.?);

    entry = demuxer.pt_to_mid.get(100);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(mid_2, entry.?);

    entry = demuxer.pt_to_mid.get(105);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(mid_3, entry.?);

    entry = demuxer.pt_to_mid.get(106);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(mid_3, entry.?);
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

test "registerRandomSsrc: returns unique ssrcs and tracks them" {
    const io = std.testing.io;

    var demuxer = init(std.testing.allocator);
    defer demuxer.deinit();

    const first = try demuxer.registerRandomSsrc(io);
    const second = try demuxer.registerRandomSsrc(io);

    try std.testing.expect(first != second);
    try std.testing.expect(demuxer.generated_ssrc.contains(first));
    try std.testing.expect(demuxer.generated_ssrc.contains(second));
    try std.testing.expectEqual(2, demuxer.generated_ssrc.count());
}

test "getMid: falls back to the mid header extension when ssrc is unknown" {
    const io = std.testing.io;

    var demuxer = init(std.testing.allocator);
    defer demuxer.deinit();

    var session = try testSdpSession(std.testing.allocator);
    defer session.deinit(std.testing.allocator);

    try demuxer.updateMaps(io, &session);
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

    try std.testing.expectEqual(mid_1, (try demuxer.getMid(io, &packet)).?);
    try std.testing.expect(demuxer.ssrc_to_mid.contains(packet.header.ssrc));
    try std.testing.expectEqual(mid_1, (try demuxer.getMid(io, &packet)).?);
}
