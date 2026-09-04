const std = @import("std");
const webrtc = @import("webrtc");

const Io = std.Io;

pub fn readSdpFromStdin(io: Io, allocator: std.mem.Allocator) !std.json.Parsed(webrtc.SessionDescription) {
    var base64_buffer: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &base64_buffer);

    var base64_offer: []const u8 = try stdin.interface.takeDelimiterExclusive('\n');
    base64_offer = std.mem.trimEnd(u8, base64_offer, "\r");

    const base64_decoder = std.base64.standard.Decoder;
    const offer_size = try base64_decoder.calcSizeForSlice(base64_offer);
    const offer = try allocator.alloc(u8, offer_size);
    defer allocator.free(offer);

    try base64_decoder.decode(offer, base64_offer);
    const value = try std.json.parseFromSlice(webrtc.SessionDescription, allocator, offer, .{});

    return value;
}

pub fn writeSdpToStdout(io: Io, allocator: std.mem.Allocator, pc: *webrtc.PeerConnection) !void {
    var local_desc = (try pc.getLocalDescription()).?;
    defer local_desc.deinit(allocator);

    var writer = Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var formatter = std.json.Formatter(webrtc.SessionDescription){
        .value = local_desc,
        .options = .{},
    };
    try formatter.format(&writer.writer);

    var stdout = Io.File.stdout().writer(io, &.{});

    const base64_encoder = std.base64.standard.Encoder;
    try base64_encoder.encodeWriter(&stdout.interface, writer.written());
    try stdout.interface.writeAll("\n");
    try stdout.flush();
}

pub fn rand_string(io: Io, buffer: []u8) void {
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    var rng = std.Random.DefaultPrng.init(@bitCast(Io.Timestamp.now(io, .awake).toMilliseconds()));
    var r = rng.random();
    for (buffer) |*c| {
        const idx = r.intRangeAtMost(usize, 0, charset.len - 1);
        c.* = charset[idx];
    }
}
