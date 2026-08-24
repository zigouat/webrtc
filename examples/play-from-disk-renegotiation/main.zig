const std = @import("std");
const builtin = @import("builtin");
const media = @import("media");
const ivf = @import("ivf");
const rtp = @import("rtp");
const webrtc = @import("webrtc");

const Io = std.Io;
const html_file = @embedFile("index.html");

var grp: Io.Group = undefined;
var app_state: AppState = undefined;

const Handler = struct {
    io: std.Io,
    gathering_done: std.Io.Event = .unset,
    connected: std.Io.Event = .unset,
    done: std.Io.Event = .unset,

    fn peerConnectionHandler(handler: *Handler) webrtc.PeerConnectionHandler {
        return .{
            .userdata = handler,
            .vtable = &.{
                .onGatheringStateChange = onGatheringStateChange,
                .onConnectionStateChange = onConnectionStateChange,
            },
        };
    }

    fn onGatheringStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.GatheringState) void {
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        if (state == .complete) handler.gathering_done.set(handler.io);
    }

    fn onConnectionStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.ConnectionState) void {
        std.debug.print("[Handler] connection state: {}\n", .{state});
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        switch (state) {
            .connected => handler.connected.set(handler.io),
            .disconnected, .closed, .failed => handler.done.set(handler.io),
            else => {},
        }
    }
};

const AppState = struct {
    handler: *Handler,
    pc: webrtc.PeerConnection,
    file_path: []const u8,
    senders: std.ArrayList(*webrtc.RtpSender) = .empty,

    fn init(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, media_engine: *webrtc.MediaEngine) !AppState {
        const handler = try allocator.create(Handler);
        errdefer allocator.destroy(handler);
        handler.* = .{ .io = io };

        return .{
            .handler = handler,
            .pc = try webrtc.PeerConnection.init(io, allocator, .{
                .handler = handler.peerConnectionHandler(),
                .media_engine = media_engine,
                .rtc_configuration = .{
                    .ice_servers = &.{.{ .url = "stun:stun.l.google.com:19302" }},
                },
            }),
            .file_path = file_path,
        };
    }

    fn deinit(self: *AppState, allocator: std.mem.Allocator) void {
        self.pc.deinit();
        self.senders.deinit(allocator);
        allocator.destroy(self.handler);
    }

    fn addTrack(self: *AppState, allocator: std.mem.Allocator, offer: webrtc.SessionDescription) !void {
        const io = self.handler.io;

        var buf: [8]u8 = @splat(0);
        var stream: [16]u8 = @splat(0);
        io.random(&buf);
        try std.crypto.codecs.hex.encode(&stream, &buf, .lower);

        const sender = try self.pc.addTrack(.init(io, .video), &stream);
        try self.senders.append(allocator, sender);

        try self.pc.setRemoteDescription(offer);
        const answer = try self.pc.createAnswer();
        try self.pc.setLocalDescription(answer);
        try self.handler.gathering_done.wait(io);

        try grp.concurrent(io, sendMediaData, .{ io, allocator, self.file_path, sender, &self.handler.connected });
    }

    fn removeTrack(self: *AppState, offer: webrtc.SessionDescription) !void {
        if (self.senders.items.len == 0) return;
        if (self.senders.pop()) |sender| {
            const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
            tr.removeTrack();

            try self.pc.setRemoteDescription(offer);
            const answer = try self.pc.createAnswer();
            try self.pc.setLocalDescription(answer);
        }
    }

    fn waitForCloseEvent(self: *AppState) !void {
        try self.handler.done.wait(self.handler.io);
    }

    fn sendMediaData(io: Io, allocator: std.mem.Allocator, path: []const u8, sender: *webrtc.RtpSender, connected: *Io.Event) !void {
        doSendMediaData(io, allocator, path, sender, connected) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => |e| std.log.err("Error occurred while sending file: {}", .{e}),
        };
    }

    fn doSendMediaData(io: Io, allocator: std.mem.Allocator, path: []const u8, sender: *webrtc.RtpSender, connected: *Io.Event) !void {
        var file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var buffer: [1024]u8 = @splat(0);
        var reader = file.reader(io, &buffer);
        var ivf_reader = ivf.Reader.init(&reader.interface) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => |e| return e,
        };

        const video_stream = &ivf_reader.stream;

        const start_timestamp = Io.Clock.now(.awake, io).toMilliseconds();
        const clock_rate = sender.codecs[0].rtp_codec.clock_rate;

        try connected.wait(io);

        var curr_packet = try ivf_reader.next(allocator);
        defer if (curr_packet) |*p| p.deinit(allocator);

        outer: while (true) {
            const elapsed: u64 = @intCast(std.Io.Clock.now(.awake, io).toMilliseconds() - start_timestamp);

            while (true) {
                if (curr_packet == null) break :outer;
                const dts = elapsed * video_stream.time_base.den / std.time.ms_per_s;
                if (curr_packet.?.dts >= dts) break;

                var p = curr_packet.?;
                p.scaleTimestamps(video_stream.time_base, .ofDen(clock_rate));
                curr_packet = null;
                defer p.deinit(allocator);

                try sender.sendSample(&p);

                curr_packet = try ivf_reader.next(allocator);
            }

            try io.sleep(.fromMilliseconds(10), .awake);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    grp = .init;
    defer grp.cancel(io);

    const file_path = blk: {
        var arg_iterator = try init.minimal.args.iterateAllocator(init.gpa);
        defer arg_iterator.deinit();
        _ = arg_iterator.next();
        const path = arg_iterator.next() orelse return error.FilePathNotProvided;
        break :blk try allocator.dupe(u8, path);
    };
    defer allocator.free(file_path);

    var media_engine = webrtc.MediaEngine.init(.{});
    try media_engine.registerCodec(allocator, .video, .{
        .mime_type = webrtc.MediaEngine.MimeType.VP8,
        .clock_rate = 90_000,
    });
    defer media_engine.deinit(allocator);

    app_state = try AppState.init(io, allocator, file_path, &media_engine);
    defer app_state.deinit(allocator);

    try grp.concurrent(io, startHttpServer, .{ io, allocator });
    try app_state.waitForCloseEvent();
}

fn startHttpServer(io: Io, allocator: std.mem.Allocator) !void {
    doStartHttpServer(io, allocator) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| std.log.err("Error while starting http server: {}", .{e}),
    };
}

fn doStartHttpServer(io: Io, allocator: std.mem.Allocator) !void {
    const addr: Io.net.IpAddress = .{ .ip4 = .unspecified(9000) };
    var server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer server.deinit(io);

    std.log.info("Http server started listening on port 9000...", .{});

    while (server.accept(io)) |client_socket| {
        try grp.concurrent(io, handleClientConnection, .{ io, allocator, client_socket });
    } else |_| {}
}

fn handleClientConnection(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream) !void {
    doHandleClientConnection(io, allocator, stream) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

fn doHandleClientConnection(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream) !void {
    defer stream.close(io);

    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;

    var r = stream.reader(io, &in_buffer);
    var w = stream.writer(io, &out_buffer);

    var http_server = std.http.Server.init(&r.interface, &w.interface);
    var req = try http_server.receiveHead();

    if (std.mem.eql(u8, "/", req.head.target)) {
        try req.respond(html_file, .{ .transfer_encoding = .none });
    } else if (std.mem.eql(u8, req.head.target, "/addVideo") and req.head.method == .POST) {
        std.log.info("Add a new video track", .{});
        var parsed = try readRequestContent(allocator, &req);
        defer parsed.deinit();

        try app_state.addTrack(allocator, parsed.value);
        try writeLocalDescription(allocator, &req);
    } else if (std.mem.eql(u8, req.head.target, "/removeVideo") and req.head.method == .POST) {
        std.log.info("Remove video", .{});
        var parsed = try readRequestContent(allocator, &req);
        defer parsed.deinit();

        app_state.removeTrack(parsed.value) catch |err| {
            std.log.err("Error while removing video track: {}", .{err});
            return;
        };
        try writeLocalDescription(allocator, &req);
    }
}

fn readRequestContent(allocator: std.mem.Allocator, req: *std.http.Server.Request) !std.json.Parsed(webrtc.SessionDescription) {
    const offer = try allocator.alloc(u8, req.head.content_length.?);
    defer allocator.free(offer);

    var reader = req.readerExpectNone(&.{});
    try reader.readSliceAll(offer);

    return try std.json.parseFromSlice(webrtc.SessionDescription, allocator, offer, .{});
}

fn writeLocalDescription(allocator: std.mem.Allocator, req: *std.http.Server.Request) !void {
    var body_writer = try req.respondStreaming(&.{}, .{
        .respond_options = .{ .transfer_encoding = .none },
    });

    var answer = (try app_state.pc.getLocalDescription()).?;
    defer answer.deinit(allocator);

    std.log.info("Answer:\n{s}\n", .{answer.sdp});

    const formatter = std.json.fmt(answer, .{});
    try formatter.format(&body_writer.writer);

    try body_writer.flush();
}
