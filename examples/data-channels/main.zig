const std = @import("std");
const webrtc = @import("webrtc");
const common = @import("common");

const Io = std.Io;

pub const std_options = std.Options{ .log_level = .info };

const Handler = struct {
    io: Io,
    gathering_done: Io.Event,
    done: Io.Event,
    grp: Io.Group,
    pc: *webrtc.PeerConnection = undefined,

    fn init(io: Io) Handler {
        return Handler{
            .io = io,
            .gathering_done = .unset,
            .done = .unset,
            .grp = .init,
        };
    }

    fn peerConnectionHandler(handler: *Handler) webrtc.PeerConnectionHandler {
        return .{
            .userdata = handler,
            .vtable = &.{
                .onGatheringStateChange = onGatheringStateChange,
                .onConnectionStateChange = onConnectionStateChange,
                .onDataChannel = onDataChannel,
            },
        };
    }

    fn onGatheringStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.GatheringState) void {
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        if (state == .complete) handler.gathering_done.set(handler.io);
    }

    fn onConnectionStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.ConnectionState) void {
        std.log.info("Connection state: {}\n", .{state});
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        if (state == .closed or state == .failed) handler.done.set(handler.io);
    }

    fn onDataChannel(userdata: ?*anyopaque, event: webrtc.DataChannel.Event) void {
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .new => |id| std.log.info("New data channel: {}", .{id}),
            .open => |id| {
                std.log.info("Data channel open: {}", .{id});
                handler.grp.concurrent(handler.io, sendMessage, .{ handler.io, handler.pc, id }) catch @panic("ConcurrencyUnavailable");
            },
            .close => |id| std.log.info("Data channel closed: {}", .{id}),
            .message => |msg| std.debug.print("[{}]: {s}\n", .{ msg.channel_id, msg.data }),
        }
    }

    fn sendMessage(io: Io, pc: *webrtc.PeerConnection, channel_id: webrtc.DataChannel.ChannelId) !void {
        var message: [20]u8 = @splat(0);

        while (true) {
            try io.sleep(.fromSeconds(5), .awake);
            common.rand_string(io, &message);
            pc.sendDataChannelMessage(channel_id, &message) catch return;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var media_engine = webrtc.MediaEngine.init(.{});
    defer media_engine.deinit(init.gpa);

    var handler = Handler.init(io);
    var pc = try webrtc.PeerConnection.init(io, init.gpa, .{
        .handler = handler.peerConnectionHandler(),
        .media_engine = &media_engine,
    });
    defer pc.deinit();

    handler.pc = &pc;

    const offer = try common.readSdpFromStdin(io, init.gpa);
    defer offer.deinit();

    try pc.setRemoteDescription(offer.value);
    const answer = try pc.createAnswer();
    try pc.setLocalDescription(answer);

    try handler.gathering_done.wait(io);
    try common.writeSdpToStdout(io, init.gpa, &pc);

    try handler.done.wait(io);
}
