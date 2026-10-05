const std = @import("std");
const builtin = @import("builtin");
const media = @import("media");
const ivf = @import("ivf");
const rtp = @import("rtp");
const webrtc = @import("webrtc");
const ice = @import("ice");
const common = @import("common");
const IvfReader = common.IvfReader;

const Io = std.Io;
const html_file = @embedFile("index.html");

var grp: Io.Group = undefined;
var conn_ctx: ConnectionContext = undefined;

const ConnectionContext = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    done: std.Io.Event,
    connected: std.Io.Event,
    send_buffer: [1500]u8,
    recv_buffer: [1500]u8,
    mutex: Io.Mutex,
    prng: std.Random.DefaultCsprng,
    senders: std.ArrayList(u32),
    file_path: []const u8,

    fn init(
        conn: *ConnectionContext,
        io: std.Io,
        allocator: std.mem.Allocator,
        media_engine: *webrtc.MediaEngine,
        file_path: []const u8,
    ) !void {
        var if_it = try ice.IfIterator.init(allocator, .{});
        defer if_it.deinit(allocator);

        const addr = if_it.next() orelse return error.NoNetworkInterface;
        const socket = try addr.bind(io, .{ .mode = .dgram });
        errdefer socket.close(io);

        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try io.randomSecure(&seed);
        conn.prng = std.Random.DefaultCsprng.init(seed);

        conn.pc = try .init(io, allocator, .{
            .media_engine = media_engine,
            .random = conn.prng.random(),
        });
        errdefer conn.pc.deinit();

        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        try conn.pc.addLocalCandidates(&.{socket.address}, now);

        conn.io = io;
        conn.socket = socket;
        conn.done = .unset;
        conn.connected = .unset;
        conn.mutex = .init;
        conn.send_buffer = undefined;
        conn.recv_buffer = undefined;
        conn.senders = .empty;
        conn.file_path = file_path;
    }

    fn deinit(self: *ConnectionContext) void {
        self.senders.deinit(self.pc.allocator);
        self.socket.close(self.io);
        self.pc.deinit();
    }

    fn addTrack(conn: *ConnectionContext, allocator: std.mem.Allocator, offer: webrtc.SessionDescription) !void {
        var stream: [16]u8 = @splat(0);
        common.utils.randString(conn.io, &stream);

        const sender_id = try conn.pc.addTrack(.init(.video, conn.prng.random()), &stream);
        try conn.senders.append(allocator, sender_id);

        try conn.pc.setRemoteDescription(offer);
        const answer = try conn.pc.createAnswer();
        try conn.pc.setLocalDescription(answer);

        try grp.concurrent(conn.io, sendMediaData, .{ conn.pc.allocator, conn.file_path, conn, sender_id });
    }

    fn removeTrack(conn: *ConnectionContext, offer: webrtc.SessionDescription) !void {
        if (conn.senders.items.len == 0) return;
        if (conn.senders.pop()) |sender_id| {
            const tr = &conn.pc.getTransceivers()[sender_id];
            tr.removeTrack();

            try conn.pc.setRemoteDescription(offer);
            const answer = try conn.pc.createAnswer();
            try conn.pc.setLocalDescription(answer);
        }
    }

    fn receive(conn: *ConnectionContext) !void {
        while (true) {
            const inc = conn.socket.receive(conn.io, &conn.recv_buffer) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };

            const now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            try conn.mutex.lock(conn.io);
            defer conn.mutex.unlock(conn.io);

            _ = conn.pc.handleRead(.{
                .data = inc.data,
                .from = &inc.from,
                .to = &conn.socket.address,
            }, now) catch continue;

            conn.handle(now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        }
    }

    fn onTimeout(conn: *ConnectionContext) !void {
        while (true) {
            const now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();

            const deadline = blk: {
                try conn.mutex.lock(conn.io);
                defer conn.mutex.unlock(conn.io);

                _ = conn.pc.handleTimeout(now, 0) catch {};
                conn.handle(now) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {},
                };
                break :blk conn.pc.pollTimeout() orelse now + 50;
            };

            try conn.io.sleep(.fromMilliseconds(deadline - now), .awake);
        }
    }

    fn send(conn: *ConnectionContext, sender_id: webrtc.PeerConnection.RtpSenderID, sample: *const media.Packet) !void {
        var buffer: [1500]u8 = undefined;
        const now = Io.Timestamp.now(conn.io, .awake).toMicroseconds();

        try conn.mutex.lock(conn.io);
        defer conn.mutex.unlock(conn.io);

        const sender = &conn.pc.transceivers.items[sender_id].sender;
        var it = try sender.handleMediaPacketWrite(sample);
        while (try it.next(&buffer, now)) |message| {
            try conn.socket.send(conn.io, message.to, message.data);
        }
    }

    fn handle(conn: *ConnectionContext, now: i64) !void {
        while (conn.pc.pollEvent()) |event| switch (event) {
            .connection_state => |state| switch (state) {
                .connected => conn.connected.set(conn.io),
                .disconnected, .closed, .failed => conn.done.set(conn.io),
                else => {},
            },
            else => {},
        };

        while (try conn.pc.pollTransmit(&conn.send_buffer, now)) |message| {
            try conn.socket.send(conn.io, message.to, message.data);
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

    try conn_ctx.init(io, allocator, &media_engine, file_path);
    defer conn_ctx.deinit();

    try grp.concurrent(io, ConnectionContext.receive, .{&conn_ctx});
    try grp.concurrent(io, ConnectionContext.onTimeout, .{&conn_ctx});
    try grp.concurrent(io, startHttpServer, .{ io, allocator });
    try conn_ctx.done.wait(io);
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

        try conn_ctx.addTrack(allocator, parsed.value);
        writeLocalDescription(allocator, &req) catch |err| switch (err) {
            error.WriteFailed => return w.err.?,
            else => |e| return e,
        };
    } else if (std.mem.eql(u8, req.head.target, "/removeVideo") and req.head.method == .POST) {
        std.log.info("Remove video", .{});
        var parsed = try readRequestContent(allocator, &req);
        defer parsed.deinit();

        try conn_ctx.removeTrack(parsed.value);

        writeLocalDescription(allocator, &req) catch |err| switch (err) {
            error.WriteFailed => return w.err.?,
            else => |e| return e,
        };
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

    var answer = (try conn_ctx.pc.getLocalDescription()).?;
    defer answer.deinit(allocator);

    std.log.info("Answer:\n{s}\n", .{answer.sdp});

    const formatter = std.json.fmt(answer, .{});
    try formatter.format(&body_writer.writer);

    try body_writer.flush();
}

fn sendMediaData(
    allocator: std.mem.Allocator,
    path: []const u8,
    conn: *ConnectionContext,
    sender_id: webrtc.PeerConnection.RtpSenderID,
) !void {
    try conn.connected.wait(conn.io);

    var ivf_reader: IvfReader = undefined;
    ivf_reader.init(conn.io, path) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return,
    };
    defer ivf_reader.deinit(allocator);

    while (true) {
        const now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();

        while (true) {
            var maybe_packet = ivf_reader.next(allocator, now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };

            if (maybe_packet) |*packet| {
                defer packet.deinit(allocator);
                conn.send(sender_id, packet) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return,
                };
                continue;
            }

            break;
        }

        try conn.io.sleep(.fromMilliseconds(10), .awake);
    }
}
