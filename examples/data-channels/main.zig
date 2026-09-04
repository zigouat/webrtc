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
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        if (state == .closed or state == .failed) handler.done.set(handler.io);
    }

    fn onDataChannel(userdata: ?*anyopaque, data_channel: *webrtc.DataChannel) void {
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        data_channel.registerCallback(handler, receiveData);
    }

    fn receiveData(userdata: ?*anyopaque, data_channel: *webrtc.DataChannel, event: webrtc.DataChannel.Event) void {
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .open => {
                std.log.info("Data channel {s} opened", .{data_channel.label});
                handler.grp.concurrent(handler.io, sendMessage, .{ handler.io, data_channel }) catch @panic("ConcurrencyUnavailable");
            },
            .text_message => |msg| std.debug.print("[{s}]: {s}\n", .{ data_channel.label, msg }),
            .close => {
                std.log.info("Data channel {s} closed", .{data_channel.label});
                handler.grp.cancel(handler.io);
            },
            else => {},
        }
    }

    fn sendMessage(io: Io, data_channel: *webrtc.DataChannel) !void {
        var message: [20]u8 = @splat(0);

        while (true) {
            try io.sleep(.fromSeconds(5), .awake);
            common.rand_string(io, &message);
            data_channel.sendText(&message) catch return;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    webrtc.SctpRuntime.init();
    defer webrtc.SctpRuntime.deinit();

    var media_engine = webrtc.MediaEngine.init(.{});
    defer media_engine.deinit(init.gpa);

    var handler = Handler.init(io);
    var pc = try webrtc.PeerConnection.init(io, init.gpa, .{
        .handler = handler.peerConnectionHandler(),
        .media_engine = &media_engine,
    });
    defer pc.deinit();

    const offer = try common.readSdpFromStdin(io, init.gpa);
    defer offer.deinit();

    try pc.setRemoteDescription(offer.value);
    const answer = try pc.createAnswer();
    try pc.setLocalDescription(answer);

    try handler.gathering_done.wait(io);
    try common.writeSdpToStdout(io, init.gpa, &pc);

    try handler.done.wait(io);
}
