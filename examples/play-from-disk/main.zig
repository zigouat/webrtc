const std = @import("std");
const media = @import("media");
const ivf = @import("ivf");
const rtp = @import("rtp");
const webrtc = @import("webrtc");
const ice = @import("ice");
const IvfReader = @import("common").IvfReader;

const html_file = @embedFile("index.html");
const Io = std.Io;

var grp: Io.Group = .init;

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

    fn init(conn: *ConnectionContext, io: std.Io, allocator: std.mem.Allocator, media_engine: *webrtc.MediaEngine) !void {
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
    }

    fn deinit(self: *ConnectionContext) void {
        self.socket.close(self.io);
        self.pc.deinit();
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

    var arg_iterator = try init.minimal.args.iterateAllocator(init.gpa);
    defer arg_iterator.deinit();
    _ = arg_iterator.next();
    const file_path = arg_iterator.next() orelse return error.InputFileRequired;

    var ivf_reader: IvfReader = undefined;
    try ivf_reader.init(io, file_path);
    defer ivf_reader.deinit(allocator);

    var media_engine = webrtc.MediaEngine.init(.{});
    try media_engine.registerCodec(allocator, .video, .{
        .mime_type = webrtc.MediaEngine.MimeType.VP8,
        .clock_rate = 90_000,
    });
    defer media_engine.deinit(allocator);

    var conn: ConnectionContext = undefined;
    try conn.init(io, allocator, &media_engine);
    defer conn.deinit();

    const sender_id = try conn.pc.addTrack(.initWithId("video-track", .video), "video-stream");

    try grp.concurrent(io, startHttpServer, .{ allocator, &conn });
    try grp.concurrent(io, ConnectionContext.receive, .{&conn});
    try grp.concurrent(io, ConnectionContext.onTimeout, .{&conn});
    try grp.concurrent(io, sendMediaData, .{ allocator, &ivf_reader, &conn, sender_id });

    try conn.done.wait(io);
    std.log.warn("Peer disconnected, exiting...", .{});
    grp.cancel(io);
}

fn startHttpServer(allocator: std.mem.Allocator, conn: *ConnectionContext) !void {
    doStartHttpServer(allocator, conn) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| std.log.err("Error while starting http server: {}", .{e}),
    };
}

fn doStartHttpServer(allocator: std.mem.Allocator, conn: *ConnectionContext) !void {
    const addr: Io.net.IpAddress = .{ .ip4 = .unspecified(9000) };
    var server = try addr.listen(conn.io, .{ .mode = .stream, .reuse_address = true });
    defer server.deinit(conn.io);

    std.log.info("Http server started listening on port 9000...", .{});

    while (server.accept(conn.io)) |client_socket| {
        try grp.concurrent(conn.io, handleClientConnection, .{ allocator, conn, client_socket });
    } else |err| return err;
}

fn handleClientConnection(allocator: std.mem.Allocator, conn: *ConnectionContext, stream: Io.net.Stream) !void {
    doHandleClientConnection(allocator, conn, stream) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

fn doHandleClientConnection(allocator: std.mem.Allocator, conn: *ConnectionContext, stream: Io.net.Stream) !void {
    defer stream.close(conn.io);

    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;

    var r = stream.reader(conn.io, &in_buffer);
    var w = stream.writer(conn.io, &out_buffer);

    var http_server = std.http.Server.init(&r.interface, &w.interface);
    var req = http_server.receiveHead() catch |err| switch (err) {
        error.ReadFailed => return r.err.?,
        else => |e| return e,
    };

    if (std.mem.eql(u8, "/", req.head.target)) {
        try req.respond(html_file, .{ .transfer_encoding = .none });
    } else if (std.mem.eql(u8, req.head.target, "/offer") and req.head.method == .GET) {
        std.log.info("Create offer", .{});
        const offer = try conn.pc.createOffer();
        try conn.pc.setLocalDescription(offer);

        var body_writer = try req.respondStreaming(&.{}, .{
            .respond_options = .{ .transfer_encoding = .none },
        });
        try conn.pc.writeLocalDescription(&body_writer.writer);
        try body_writer.flush();
    } else if (std.mem.eql(u8, req.head.target, "/answer") and req.head.method == .POST) {
        std.log.info("Set remote description", .{});
        const answer = allocator.alloc(u8, req.head.content_length.?) catch return;
        defer allocator.free(answer);

        var reader = req.readerExpectNone(&.{});
        try reader.readSliceAll(answer);
        try req.respond(&.{}, .{ .transfer_encoding = .none });
        try conn.pc.setRemoteDescription(.{ .type = .answer, .sdp = answer });
    }
}

fn sendMediaData(
    allocator: std.mem.Allocator,
    ivf_reader: *IvfReader,
    conn: *ConnectionContext,
    sender_id: webrtc.PeerConnection.RtpSenderID,
) !void {
    try conn.connected.wait(conn.io);

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
