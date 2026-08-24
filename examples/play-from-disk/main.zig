const std = @import("std");
const media = @import("media");
const ivf = @import("ivf");
const rtp = @import("rtp");
const webrtc = @import("webrtc");

const Io = std.Io;

const html_file = @embedFile("index.html");
const js_file = @embedFile("pc.js");

var pc: webrtc.PeerConnection = undefined;
var grp: Io.Group = .init;

const SenderHandler = struct {
    io: std.Io,
    gathering_done: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    connected: std.Io.Event = .unset,

    fn peerConnectionHandler(handler: *SenderHandler) webrtc.PeerConnectionHandler {
        return .{
            .userdata = handler,
            .vtable = &.{
                .onGatheringStateChange = onGatheringStateChange,
                .onConnectionStateChange = onConnectionStateChange,
            },
        };
    }

    fn onGatheringStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.GatheringState) void {
        const handler: *SenderHandler = @ptrCast(@alignCast(userdata.?));
        if (state == .complete) handler.gathering_done.set(handler.io);
    }

    fn onConnectionStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.ConnectionState) void {
        const handler: *SenderHandler = @ptrCast(@alignCast(userdata.?));
        switch (state) {
            .connected => handler.connected.set(handler.io),
            .disconnected, .closed, .failed => handler.done.set(handler.io),
            else => {},
        }
    }
};

const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    handler: *SenderHandler,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var arg_iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer arg_iterator.deinit();
    _ = arg_iterator.next();
    const file_path = arg_iterator.next() orelse return error.InputFileRequired;

    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [1024]u8 = @splat(0);
    var reader = file.reader(io, &buffer);
    var ivf_reader = ivf.Reader.init(&reader.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };

    var media_engine = webrtc.MediaEngine.init(.{});
    try media_engine.registerCodec(allocator, .video, .{
        .mime_type = webrtc.MediaEngine.MimeType.VP8,
        .clock_rate = 90_000,
    });
    defer media_engine.deinit(allocator);

    var handler = SenderHandler{ .io = io };

    pc = try .init(io, allocator, .{
        .media_engine = &media_engine,
        .handler = handler.peerConnectionHandler(),
    });
    defer pc.deinit();

    const sender = try pc.addTrack(.initWithId("video-track", .video), "video-stream");

    const ctx = Context{ .io = io, .allocator = allocator, .handler = &handler };
    try grp.concurrent(io, startHttpServer, .{ctx});

    const SelectEvent = union(enum) { connected: Io.Cancelable!void, done: Io.Cancelable!void };
    const Select = std.Io.Select(SelectEvent);
    var event: [1]SelectEvent = undefined;
    var select = Select.init(io, &event);

    try select.concurrent(.connected, struct {
        fn waitForConnect(h: *SenderHandler) !void {
            try h.connected.wait(h.io);
        }
    }.waitForConnect, .{&handler});

    try select.concurrent(.done, struct {
        fn waitForDone(h: *SenderHandler) !void {
            try h.done.wait(h.io);
        }
    }.waitForDone, .{&handler});

    while (true) {
        switch (try select.await()) {
            .connected => {
                std.log.info("Peer connected, starting media streaming...", .{});
                try grp.concurrent(io, sendMediaData, .{ io, allocator, &reader, &ivf_reader, sender });
            },
            .done => {
                std.log.warn("Peer disconnected, exiting...", .{});
                grp.cancel(io);
                break;
            },
        }
    }
}

fn startHttpServer(ctx: Context) !void {
    doStartHttpServer(ctx) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| std.log.err("Error while starting http server: {}", .{e}),
    };
}

fn doStartHttpServer(ctx: Context) !void {
    const addr: Io.net.IpAddress = .{ .ip4 = .unspecified(9000) };
    var server = try addr.listen(ctx.io, .{ .mode = .stream, .reuse_address = true });
    defer server.deinit(ctx.io);

    std.log.info("Http server started listening on port 9000...", .{});

    while (server.accept(ctx.io)) |client_socket| {
        try grp.concurrent(ctx.io, handleClientConnection, .{ ctx, client_socket });
    } else |_| {}
}

fn handleClientConnection(ctx: Context, stream: Io.net.Stream) !void {
    doHandleClientConnection(ctx, stream) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

fn doHandleClientConnection(ctx: Context, stream: Io.net.Stream) !void {
    defer stream.close(ctx.io);

    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;

    var r = stream.reader(ctx.io, &in_buffer);
    var w = stream.writer(ctx.io, &out_buffer);

    var http_server = std.http.Server.init(&r.interface, &w.interface);
    var req = try http_server.receiveHead();

    if (std.mem.eql(u8, "/", req.head.target)) {
        try req.respond(html_file, .{ .transfer_encoding = .none });
    } else if (std.mem.eql(u8, "/pc.js", req.head.target)) {
        try req.respond(js_file, .{
            .transfer_encoding = .none,
            .extra_headers = &[_]std.http.Header{.{ .name = "Content-Type", .value = "application/javascript" }},
        });
    } else if (std.mem.eql(u8, req.head.target, "/offer") and req.head.method == .GET) {
        std.log.info("Create offer", .{});
        const offer = try pc.createOffer();
        try pc.setLocalDescription(offer);

        try ctx.handler.gathering_done.wait(ctx.io);

        var body_writer = try req.respondStreaming(&.{}, .{ .respond_options = .{ .transfer_encoding = .none } });

        try pc.writeLocalDescription(&body_writer.writer);
        try body_writer.flush();
    } else if (std.mem.eql(u8, req.head.target, "/answer") and req.head.method == .POST) {
        std.log.info("Set remote description", .{});
        const answer = ctx.allocator.alloc(u8, req.head.content_length.?) catch return;
        defer ctx.allocator.free(answer);

        var reader = req.readerExpectNone(&.{});
        try reader.readSliceAll(answer);
        try req.respond(&.{}, .{ .transfer_encoding = .none });

        try pc.setRemoteDescription(.{ .type = .answer, .sdp = answer });
    }
}

fn sendMediaData(io: Io, allocator: std.mem.Allocator, file_reader: *std.Io.File.Reader, reader: *ivf.Reader, sender: *webrtc.RtpSender) !void {
    doSendMediaData(io, allocator, file_reader, reader, sender) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| std.log.err("Error occurred while sending file: {}", .{e}),
    };
}

fn doSendMediaData(io: Io, allocator: std.mem.Allocator, file_reader: *std.Io.File.Reader, reader: *ivf.Reader, sender: *webrtc.RtpSender) !void {
    const video_stream = &reader.stream;
    const start_timestamp = Io.Clock.now(.awake, io).toMilliseconds();

    var curr_packet = try reader.next(allocator);
    defer if (curr_packet) |*p| p.deinit(allocator);

    const dest_time_base = media.Rational.ofDen(90_000);

    outer: while (true) {
        const timestamp = std.Io.Clock.now(.awake, io).toMilliseconds();
        const elapsed: u64 = @intCast(timestamp - start_timestamp);

        while (true) {
            if (curr_packet == null) break :outer;
            const dts = elapsed * video_stream.time_base.den / std.time.ms_per_s;
            if (curr_packet.?.dts >= dts) break;

            var p = curr_packet.?;
            defer p.deinit(allocator);

            p.scaleTimestamps(video_stream.time_base, dest_time_base);
            try sender.sendSample(&p);

            curr_packet = reader.next(allocator) catch |err| switch (err) {
                error.ReadFailed => return file_reader.err.?,
                else => |e| return e,
            };
        }

        try io.sleep(.fromMilliseconds(10), .awake);
    }

    // TODO: close peer connection
}
