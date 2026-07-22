const std = @import("std");
const webrtc = @import("webrtc.zig");

const RtpCodec = webrtc.RtpCodecParameters;

/// Returns the codecs from `a` that are also present in `b` (matched by `RtpCodecParameters.eql`),
/// including any associated RTX codecs. Result follows `b`'s order and is owned by the caller.
/// Used when building an answer, where inputs are `const` and a fresh owned slice is needed.
pub fn getCodecIntersection(allocator: std.mem.Allocator, a: []const RtpCodec, b: []const RtpCodec) ![]RtpCodec {
    var result_a: std.ArrayList(RtpCodec) = .empty;
    var result_b: std.ArrayList(RtpCodec) = .empty;
    errdefer result_a.deinit(allocator);
    defer result_b.deinit(allocator);

    for (b) |codec_b| if (!codec_b.isRtx()) {
        for (a) |codec_a| if (!codec_a.isRtx()) {
            if (codec_b.eql(&codec_a)) {
                try result_a.append(allocator, codec_a);
                try result_b.append(allocator, codec_b);
            }
        };
    };

    for (b) |codec_b| if (codec_b.isRtx()) {
        const apt = codec_b.fmtp_params.?.rtx.apt;
        const maybe_index = blk: {
            for (result_b.items, 0..) |codec, idx| if (codec.payload_type == apt) break :blk idx;
            break :blk null;
        };

        if (maybe_index == null) continue;

        const src_apt = result_a.items[maybe_index.?].payload_type;
        for (a) |codec_a| if (codec_a.isRtx() and codec_a.fmtp_params.?.rtx.apt == src_apt) {
            try result_a.append(allocator, codec_a);
            try result_b.append(allocator, codec_b);
            break;
        };
    };

    return try result_a.toOwnedSlice(allocator);
}

/// Reorders `a` and `b` in place so matched codecs (and their RTX pairs) line up by index, then
/// returns the aligned prefixes `.{ a_matched, b_matched }`, which borrow from the inputs.
pub fn intersectCodecs(a: []RtpCodec, b: []RtpCodec) error{NoCommonMedia}!struct { []const RtpCodec, []const RtpCodec } {
    sortByRtx(a);
    sortByRtx(b);

    var idx: usize = 0;
    while (idx < a.len and !a[idx].isRtx()) : (idx += 1) {
        const match: ?usize = blk: {
            var p: usize = idx;
            while (p < b.len and !a[idx].eql(&b[p])) : (p += 1) {}
            break :blk if (p < b.len) p else null;
        };

        if (match) |pos| swap(b, idx, pos) else break;
    }

    if (idx == 0) return error.NoCommonMedia;

    var offset = idx;
    for (0..idx) |i| {
        const a_codec = &a[i];
        const a_rtx_pos = findRtx(a[offset..], a_codec.payload_type);
        if (a_rtx_pos == null) continue;

        const b_codec = &b[i];
        const b_rtx_pos = findRtx(b[offset..], b_codec.payload_type);
        if (b_rtx_pos == null) continue;

        swap(a, offset, a_rtx_pos.? + offset);
        swap(b, offset, b_rtx_pos.? + offset);

        offset += 1;
    }

    return .{ a[0..offset], b[0..offset] };
}

/// Index of the RTX codec whose `apt` references payload type `pt`, if any.
fn findRtx(codecs: []const RtpCodec, pt: u8) ?usize {
    for (codecs, 0..) |*codec, idx| if (codec.isRtx() and codec.fmtp_params.?.rtx.apt == pt) {
        return idx;
    };

    return null;
}

/// Moves RTX codecs after the primary codecs in place.
fn sortByRtx(codecs: []RtpCodec) void {
    var idx: usize = 0;
    while (idx < codecs.len) : (idx += 1) {
        const codec = &codecs[idx];
        if (!codec.isRtx()) continue;

        const pos = blk: {
            var pos: usize = idx + 1;
            while (pos < codecs.len and codecs[pos].isRtx()) : (pos += 1) {}
            break :blk if (pos < codecs.len) pos else null;
        };

        if (pos == null) return;
        swap(codecs, idx, pos.?);
    }
}

fn swap(codecs: []RtpCodec, i: usize, j: usize) void {
    const tmp = codecs[i];
    codecs[i] = codecs[j];
    codecs[j] = tmp;
}

const testing = std.testing;

fn vp8(pt: u8) RtpCodec {
    return .{ .payload_type = pt, .mime_type = webrtc.MimeType.VP8, .clock_rate = 90_000 };
}

fn opus(pt: u8) RtpCodec {
    return .{ .payload_type = pt, .mime_type = webrtc.MimeType.Opus, .clock_rate = 48_000, .channels = 2 };
}

fn rtx(pt: u8, apt: u8) RtpCodec {
    return .{ .payload_type = pt, .mime_type = webrtc.MimeType.Rtx, .clock_rate = 90_000, .fmtp_params = .{ .rtx = .{ .apt = apt } } };
}

test "getCodecIntersection: keeps matching a-side codecs, in b order" {
    const a = [_]RtpCodec{ vp8(96), opus(111) };
    const b = [_]RtpCodec{ opus(111), vp8(100) };

    const result = try getCodecIntersection(testing.allocator, &a, &b);
    defer testing.allocator.free(result);

    // Follows b's order (opus, then vp8) but carries a's payload types.
    try testing.expectEqual(2, result.len);
    try testing.expectEqual(111, result[0].payload_type);
    try testing.expectEqual(96, result[1].payload_type);
}

test "getCodecIntersection: no common codecs returns empty" {
    const a = [_]RtpCodec{vp8(96)};
    const b = [_]RtpCodec{opus(111)};

    const result = try getCodecIntersection(testing.allocator, &a, &b);
    defer testing.allocator.free(result);

    try testing.expectEqual(0, result.len);
}

test "getCodecIntersection: includes the associated rtx codec" {
    const a = [_]RtpCodec{ vp8(96), rtx(97, 96) };
    const b = [_]RtpCodec{ vp8(100), rtx(101, 100) };

    const result = try getCodecIntersection(testing.allocator, &a, &b);
    defer testing.allocator.free(result);

    try testing.expectEqual(2, result.len);
    try testing.expectEqual(96, result[0].payload_type);
    try testing.expect(result[1].isRtx());
    try testing.expectEqual(97, result[1].payload_type);
    try testing.expectEqual(96, result[1].fmtp_params.?.rtx.apt);
}

test "intersectCodecs: aligns the matched codec on both sides" {
    var a = [_]RtpCodec{ vp8(96), opus(111) };
    var b = [_]RtpCodec{vp8(100)};

    const result = try intersectCodecs(&a, &b);

    try testing.expectEqual(1, result.@"0".len);
    try testing.expectEqual(1, result.@"1".len);
    try testing.expectEqual(96, result.@"0"[0].payload_type);
    try testing.expectEqual(100, result.@"1"[0].payload_type);
}

test "intersectCodecs: no common codecs returns error" {
    var a = [_]RtpCodec{vp8(96)};
    var b = [_]RtpCodec{opus(111)};

    try testing.expectError(error.NoCommonMedia, intersectCodecs(&a, &b));
}

test "intersectCodecs: pairs the associated rtx codecs" {
    var a = [_]RtpCodec{ vp8(96), rtx(97, 96) };
    var b = [_]RtpCodec{ vp8(100), rtx(101, 100) };

    const result = try intersectCodecs(&a, &b);

    try testing.expectEqual(2, result.@"0".len);
    try testing.expectEqual(2, result.@"1".len);
    try testing.expect(result.@"0"[1].isRtx());
    try testing.expectEqual(97, result.@"0"[1].payload_type);
    try testing.expectEqual(101, result.@"1"[1].payload_type);
}
