const std = @import("std");
const webrtc = @import("webrtc");
const common = @import("common");

const Io = std.Io;

pub const std_options = std.Options{ .log_level = .info };

const ReflectHandler = struct {
    io: std.Io,
    gathering_done: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    audio_sender: *webrtc.RtpSender = undefined,
    video_sender: *webrtc.RtpSender = undefined,

    fn peerConnectionHandler(handler: *ReflectHandler) webrtc.PeerConnectionHandler {
        return .{
            .userdata = handler,
            .vtable = &.{
                .onGatheringStateChange = onGatheringStateChange,
                .onConnectionStateChange = onConnectionStateChange,
                .onTrack = onTrack,
            },
        };
    }

    fn onGatheringStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.GatheringState) void {
        const handler: *ReflectHandler = @ptrCast(@alignCast(userdata.?));
        if (state == .complete) handler.gathering_done.set(handler.io);
    }

    fn onConnectionStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.ConnectionState) void {
        std.log.info("Connection state changed: {s}", .{@tagName(state)});
        const handler: *ReflectHandler = @ptrCast(@alignCast(userdata.?));
        switch (state) {
            .closed, .failed => handler.done.set(handler.io),
            else => {},
        }
    }

    fn onTrack(userdata: ?*anyopaque, event: webrtc.RtpTransceiver.TrackEventInit) void {
        const handler: *ReflectHandler = @ptrCast(@alignCast(userdata.?));
        std.log.info("New remote track({s}): {s}", .{ @tagName(event.track.kind), event.track.id });

        const s = switch (event.track.kind) {
            .video => handler.video_sender,
            .audio => handler.audio_sender,
        };

        event.receiver.registerCallback(s, sendBackRtp);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var grp: Io.Group = .init;
    defer grp.cancel(io);

    var media_engine = webrtc.MediaEngine.init(.{});
    try media_engine.registerDefaultCodecs(allocator);
    defer media_engine.deinit(allocator);

    var handler = ReflectHandler{ .io = io };

    var pc = try webrtc.PeerConnection.init(io, allocator, .{
        .media_engine = &media_engine,
        .handler = handler.peerConnectionHandler(),
    });
    defer pc.deinit();

    handler.video_sender = try pc.addTrack(.initWithId("video", .video), "my-stream");
    handler.audio_sender = try pc.addTrack(.initWithId("audio", .audio), "my-stream");

    const offer = try readOfferFromStdin(io, init.gpa);
    defer init.gpa.free(offer);

    const parsed = try std.json.parseFromSlice(webrtc.SessionDescription, init.gpa, offer, .{});
    defer parsed.deinit();

    try pc.setRemoteDescription(parsed.value);
    const answer = try pc.createAnswer();
    try pc.setLocalDescription(answer);

    try handler.gathering_done.wait(io);
    try common.writeSdpToStdout(io, init.gpa, &pc);

    try handler.done.wait(io);
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

fn sendBackRtp(userdata: ?*anyopaque, _: *webrtc.RtpReceiver, event: webrtc.RtpReceiver.TrackEvent) void {
    const sender: *webrtc.RtpSender = @ptrCast(@alignCast(userdata.?));

    sender.sendRtp(&event.rtp) catch |err| {
        std.log.err("Error while polling rtp: {}", .{err});
    };
}
