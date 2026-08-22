const std = @import("std");
const webrtc = @import("webrtc");

const Io = std.Io;

pub const std_options = std.Options{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var grp: Io.Group = .init;
    defer grp.cancel(io);

    var pc = try webrtc.PeerConnection.init(io, init.gpa, .{});
    defer pc.deinit();

    const sender = try pc.addTrack(.initWithId("video", .video), "my-stream");
    const audio_sender = try pc.addTrack(.initWithId("audio", .audio), "my-stream");

    const offer = try readOfferFromStdin(io, init.gpa);
    defer init.gpa.free(offer);

    const parsed = try std.json.parseFromSlice(webrtc.SessionDescription, init.gpa, offer, .{});
    defer parsed.deinit();

    try pc.setRemoteDescription(parsed.value);
    const answer = try pc.createAnswer();
    try pc.setLocalDescription(answer);

    try writeAnswerToStdout(io, init.gpa, &pc);

    while (pc.poll()) |event| switch (event) {
        .connection_state => |state| switch (state) {
            .failed => break,
            else => std.log.info("Connection state: {}", .{state}),
        },
        .track_event_init => |track_event| {
            std.log.info("New remote track({s}): {s}", .{ @tagName(track_event.track.kind), track_event.track.id });
            const s = switch (track_event.track.kind) {
                .video => sender,
                .audio => audio_sender,
            };
            track_event.receiver.registerCallback(s, sendBackRtp);
        },
        else => {},
    } else |_| {}
}

fn readOfferFromStdin(io: Io, allocator: std.mem.Allocator) ![]const u8 {
    var base64_buffer: [64 * 1024]u8 = undefined;

    std.debug.print("Paste the offer here:\n", .{});
    var stdin = Io.File.stdin().reader(io, &base64_buffer);

    var base64_offer: []const u8 = try stdin.interface.takeDelimiterExclusive('\n');
    base64_offer = std.mem.trimEnd(u8, base64_offer, "\r");

    const base64_decoder = std.base64.standard.Decoder;
    const offer_size = try base64_decoder.calcSizeForSlice(base64_offer);
    const offer = try allocator.alloc(u8, offer_size);
    errdefer allocator.free(offer);

    try base64_decoder.decode(offer, base64_offer);

    return offer;
}

fn writeAnswerToStdout(io: Io, allocator: std.mem.Allocator, pc: *webrtc.PeerConnection) !void {
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
}

fn sendBackRtp(userdata: ?*anyopaque, _: *webrtc.RtpReceiver, event: webrtc.RtpReceiver.TrackEvent) void {
    const sender: *webrtc.RtpSender = @ptrCast(@alignCast(userdata.?));

    sender.sendRtp(&event.rtp) catch |err| {
        std.log.err("Error while polling rtp: {}", .{err});
    };
}
