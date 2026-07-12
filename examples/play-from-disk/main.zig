const std = @import("std");
const builtin = @import("builtin");
const media = @import("media");
const ivf = @import("ivf");
const rtp = @import("rtp");
const webrtc = @import("webrtc");

const Io = std.Io;

const html_file = @embedFile("index.html");
const js_file = @embedFile("pc.js");

var pc: webrtc.PeerConnection = undefined;
var grp: Io.Group = .init;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var arg_iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer arg_iterator.deinit();
    _ = arg_iterator.next();
    const file_path = arg_iterator.next().?;

    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [1024]u8 = @splat(0);
    var reader = file.reader(io, &buffer);
    var ivf_reader = ivf.Reader.init(&reader.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };

    pc = try .init(io, allocator, .{});
    defer pc.deinit();

    const sender = try pc.addTrack(.initWithId("video-track", .video), "video-stream");
    try grp.concurrent(io, startHttpServer, .{ io, allocator });

    while (pc.poll()) |event| switch (event) {
        .connection_state => |state| switch (state) {
            .connected => {
                std.log.info("Peer connected", .{});
                try grp.concurrent(io, sendMediaData, .{ io, allocator, &ivf_reader, sender });
            },
            .disconnected => pc.close(),
            .closed => {
                std.log.warn("Peer closed, exiting...", .{});
                grp.cancel(io);
                return;
            },
            else => {},
        },
        else => {},
    } else |_| return;
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
    } else if (std.mem.eql(u8, "/pc.js", req.head.target)) {
        try req.respond(js_file, .{
            .transfer_encoding = .none,
            .extra_headers = &[_]std.http.Header{.{ .name = "Content-Type", .value = "application/javascript" }},
        });
    } else if (std.mem.eql(u8, req.head.target, "/offer") and req.head.method == .GET) {
        std.log.info("Create offer", .{});
        const offer = try pc.createOffer();
        try pc.setLocalDescription(offer);

        var body_writer = try req.respondStreaming(&.{}, .{ .respond_options = .{ .transfer_encoding = .none } });

        try pc.writeLocalDescription(&body_writer.writer);
        try body_writer.flush();
    } else if (std.mem.eql(u8, req.head.target, "/answer") and req.head.method == .POST) {
        std.log.info("Set remote description", .{});
        const answer = allocator.alloc(u8, req.head.content_length.?) catch return;
        defer allocator.free(answer);

        var reader = req.readerExpectNone(&.{});
        try reader.readSliceAll(answer);
        try req.respond(&.{}, .{ .transfer_encoding = .none });

        try pc.setRemoteDescription(.{ .type = .answer, .sdp = answer });
    }
}

fn sendMediaData(io: Io, allocator: std.mem.Allocator, reader: *ivf.Reader, sender: *webrtc.RtpSender) !void {
    doSendMediaData(io, allocator, reader, sender) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| std.log.err("Error occurred while sending file: {}", .{e}),
    };
}

fn doSendMediaData(io: Io, allocator: std.mem.Allocator, reader: *ivf.Reader, sender: *webrtc.RtpSender) !void {
    const video_stream = &reader.stream;
    const start_timestamp = Io.Clock.now(.awake, io).toMilliseconds();

    var curr_packet = try reader.next(allocator);
    defer if (curr_packet) |*p| p.deinit(allocator);

    outer: while (true) {
        const timestamp = std.Io.Clock.now(.awake, io).toMilliseconds();
        const elapsed: u64 = @intCast(timestamp - start_timestamp);

        while (true) {
            if (curr_packet == null) break :outer;
            const dts = elapsed * video_stream.time_base.den / std.time.ms_per_s;
            if (curr_packet.?.dts >= dts) break;

            var p = curr_packet.?;
            defer p.deinit(allocator);

            p.dts = @intCast(@divTrunc(@as(i128, p.dts) * video_stream.time_base.num * 90_000, @as(i128, video_stream.time_base.den)));
            p.pts = @intCast(@divTrunc(@as(i128, p.pts) * video_stream.time_base.num * 90_000, @as(i128, video_stream.time_base.den)));

            try sender.sendSample(&p);

            curr_packet = try reader.next(allocator);
        }

        try io.sleep(.fromMilliseconds(10), .awake);
    }

    // TODO: close peer connection
}
