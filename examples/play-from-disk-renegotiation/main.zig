const std = @import("std");
const builtin = @import("builtin");
const media = @import("media");
const ivf = @import("ivf");
const rtp = @import("rtp");
const webrtc = @import("webrtc");

const Io = std.Io;
const html_file = @embedFile("index.html");

const AppState = struct {
    pc: webrtc.PeerConnection,
    file_path: []const u8,
    senders: std.ArrayList(*webrtc.RtpSender) = .empty,

    pub fn deinit(self: *AppState, allocator: std.mem.Allocator) void {
        self.pc.deinit();
        self.senders.deinit(allocator);
    }

    pub fn addTrack(self: *AppState, io: Io, allocator: std.mem.Allocator, offer: webrtc.SessionDescription) !void {
        var buf: [8]u8 = @splat(0);
        var stream: [16]u8 = @splat(0);
        io.random(&buf);
        try std.crypto.codecs.hex.encode(&stream, &buf, .lower);

        const sender = try self.pc.addTrack(.init(io, .video), &.{&stream});
        try self.senders.append(allocator, sender);

        try self.pc.setRemoteDescription(offer);
        const answer = try self.pc.createAnswer();
        try self.pc.setLocalDescription(answer);

        if (self.pc.connection_state == .connected) {
            try grp.concurrent(io, sendMediaData, .{ io, allocator, self.file_path, sender });
        }
    }

    pub fn removeTrack(self: *AppState, offer: webrtc.SessionDescription) !void {
        if (self.senders.items.len == 0) return;
        if (self.senders.pop()) |sender| {
            const tr: *webrtc.RtpTransceiver = @alignCast(@fieldParentPtr("sender", sender));
            try self.pc.stopTransceiver(tr);

            try self.pc.setRemoteDescription(offer);
            const answer = try self.pc.createAnswer();
            try self.pc.setLocalDescription(answer);
        }
    }

    pub fn eventLoop(self: *AppState, io: Io, allocator: std.mem.Allocator) !void {
        while (self.pc.poll()) |event| switch (event) {
            .connection_state => |state| switch (state) {
                .connected => {
                    std.log.info("Peer connected", .{});
                    for (self.senders.items) |sender| {
                        try grp.concurrent(io, sendMediaData, .{ io, allocator, self.file_path, sender });
                    }
                },
                .disconnected => self.pc.close(),
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

    fn sendMediaData(io: Io, allocator: std.mem.Allocator, path: []const u8, sender: *webrtc.RtpSender) !void {
        doSendMediaData(io, allocator, path, sender) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => |e| std.log.err("Error occurred while sending file: {}", .{e}),
        };
    }

    fn doSendMediaData(io: Io, allocator: std.mem.Allocator, path: []const u8, sender: *webrtc.RtpSender) !void {
        var file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var buffer: [1024]u8 = @splat(0);
        var reader = file.readerStreaming(io, &buffer);
        var ivf_reader = try ivf.Reader.init(&reader.interface);

        const video_stream = &ivf_reader.stream;

        var vp8_pack = rtp.packetizer.VP8.init(.init(io));
        var rtp_buffer: [1300]u8 = @splat(0);

        const start_timestamp = Io.Clock.now(.awake, io).toMilliseconds();
        const clock_rate = sender.codecs[0].clock_rate;
        const time_base = video_stream.time_base;

        var curr_packet = try ivf_reader.next(allocator);
        defer if (curr_packet) |*p| p.deinit(allocator);

        outer: while (true) {
            const elapsed: u64 = @intCast(std.Io.Clock.now(.awake, io).toMilliseconds() - start_timestamp);

            while (true) {
                if (curr_packet == null) break :outer;
                const dts = elapsed * video_stream.time_base.den / std.time.ms_per_s;
                if (curr_packet.?.dts >= dts) break;

                var p = curr_packet.?;
                curr_packet = null;
                defer p.deinit(allocator);

                p.dts = @intCast(@divTrunc(@as(i128, p.dts) * time_base.num * clock_rate, @as(i128, time_base.den)));
                p.pts = @intCast(@divTrunc(@as(i128, p.pts) * time_base.num * clock_rate, @as(i128, time_base.den)));

                var it = vp8_pack.packetize(&p);
                while (it.next(&rtp_buffer)) |rtp_packet| {
                    try sender.sendRtp(&rtp_packet);
                }

                curr_packet = try ivf_reader.next(allocator);
            }

            try io.sleep(.fromMilliseconds(10), .awake);
        }

        // TODO: close peer connection
    }
};

var grp: Io.Group = undefined;
var app_state: AppState = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    grp = .init;
    defer grp.cancel(io);

    var arg_iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer arg_iterator.deinit();
    _ = arg_iterator.next();
    const file_path = arg_iterator.next().?;

    app_state = .{
        .file_path = file_path,
        .pc = try webrtc.PeerConnection.init(io, allocator, .{}),
    };
    defer app_state.deinit(allocator);

    try grp.concurrent(io, startHttpServer, .{ io, allocator });
    try app_state.eventLoop(io, allocator);
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

        std.debug.print("Offer:\n{s}\n", .{parsed.value.sdp});

        try app_state.addTrack(io, allocator, parsed.value);
        try writeLocalDescription(allocator, &req);
    } else if (std.mem.eql(u8, req.head.target, "/removeVideo") and req.head.method == .POST) {
        std.log.info("Remove video", .{});
        var parsed = try readRequestContent(allocator, &req);
        defer parsed.deinit();

        std.debug.print("Offer:\n{s}\n", .{parsed.value.sdp});

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

    std.debug.print("{s}\n", .{answer.sdp});

    const formatter = std.json.fmt(answer, .{});
    try formatter.format(&body_writer.writer);

    try body_writer.flush();
}
