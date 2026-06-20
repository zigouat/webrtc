const std = @import("std");
const webrtc = @import("webrtc.zig");

pub fn getCodecIntersection(
    allocator: std.mem.Allocator,
    a: []const webrtc.RtpCodecParameters,
    b: []const webrtc.RtpCodecParameters,
) ![]webrtc.RtpCodecParameters {
    var result_a: std.ArrayList(webrtc.RtpCodecParameters) = .empty;
    var result_b: std.ArrayList(webrtc.RtpCodecParameters) = .empty;
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

pub fn intersectCodecs(
    a: []webrtc.RtpCodecParameters,
    b: []webrtc.RtpCodecParameters,
) !struct { []const webrtc.RtpCodecParameters, []const webrtc.RtpCodecParameters } {
    sortByRtx(a);
    sortByRtx(b);

    var idx: usize = 0;
    while (idx < a.len and !a[idx].isRtx()) : (idx += 1) {
        const pos: ?usize = blk: {
            var pos: usize = idx;
            while (pos < b.len and !a[idx].eql(&b[pos])) : (pos += 1) {}
            if (pos >= b.len) break :blk null;
            break :blk if (pos < b.len) pos else null;
        };

        if (pos == null) break;
        const tmp = b[idx];
        b[idx] = b[pos.?];
        b[pos.?] = tmp;
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

fn findRtx(codecs: []const webrtc.RtpCodecParameters, pt: u8) ?usize {
    for (codecs, 0..) |*codec, idx| if (codec.isRtx() and codec.fmtp_params.?.rtx.apt == pt) {
        return idx;
    };

    return null;
}

fn sortByRtx(codecs: []webrtc.RtpCodecParameters) void {
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

fn swap(codecs: []webrtc.RtpCodecParameters, i: usize, j: usize) void {
    const tmp = codecs[i];
    codecs[i] = codecs[j];
    codecs[j] = tmp;
}
