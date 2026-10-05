const std = @import("std");
const webrtc = @import("webrtc");
const media = @import("media");
const rtp = @import("rtp");
const ice = @import("ice");
const common = @import("common");

const Io = std.Io;
const BroadcastChannel = media.BroadcastChannel(rtp.Packet, 16);
const MemoryPool = std.heap.MemoryPool([1500]u8);

const server_addr = Io.net.IpAddress{ .ip4 = .unspecified(9000) };
var queue_buffer: [1]std.json.Parsed(webrtc.SessionDescription) = undefined;
var queue: Io.Queue(std.json.Parsed(webrtc.SessionDescription)) = .init(&queue_buffer);

pub const std_options = std.Options{ .log_level = .info };

const PublisherConnection = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    done: std.Io.Event,
    connected: std.Io.Event,
    send_buffer: [1500]u8,
    recv_buffer: [1500]u8,
    mutex: Io.Mutex,
    prng: std.Random.DefaultCsprng,
    channel: *BroadcastChannel,
    memory_pool: *MemoryPool,

    const Config = struct {
        media_engine: *webrtc.MediaEngine,
        memory_pool: *MemoryPool,
        channel: *BroadcastChannel,
    };

    fn init(conn: *PublisherConnection, io: std.Io, allocator: std.mem.Allocator, config: Config) !void {
        var if_it = try ice.IfIterator.init(allocator, .{});
        defer if_it.deinit(allocator);

        const addr = if_it.next() orelse return error.NoNetworkInterface;
        const socket = try addr.bind(io, .{ .mode = .dgram });
        errdefer socket.close(io);

        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try io.randomSecure(&seed);
        conn.prng = std.Random.DefaultCsprng.init(seed);

        conn.pc = try .init(io, allocator, .{
            .media_engine = config.media_engine,
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
        conn.memory_pool = config.memory_pool;
        conn.channel = config.channel;
    }

    fn deinit(self: *PublisherConnection) void {
        self.socket.close(self.io);
        self.pc.deinit();
    }

    fn sendPli(conn: *PublisherConnection) !void {
        try conn.mutex.lock(conn.io);
        defer conn.mutex.unlock(conn.io);

        const receiver = &conn.pc.transceivers.items[0].receiver;
        const msg = try receiver.sendPli(&conn.send_buffer);
        try conn.socket.send(conn.io, msg.to, msg.data);
    }

    fn receive(conn: *PublisherConnection) !void {
        while (true) {
            const inc = conn.socket.receive(conn.io, &conn.recv_buffer) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };

            const now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            try conn.mutex.lock(conn.io);
            defer conn.mutex.unlock(conn.io);

            const read_result = conn.pc.handleRead(.{
                .data = inc.data,
                .from = &inc.from,
                .to = &conn.socket.address,
            }, now) catch continue;

            switch (read_result) {
                .rtp => |received| {
                    const buffer = conn.memory_pool.create(conn.pc.allocator) catch return;
                    const payload = received.@"1".payload;
                    @memcpy(buffer[0..payload.len], payload);
                    const packet = rtp.Packet{
                        .header = received.@"1".header,
                        .payload = buffer[0..payload.len],
                    };
                    conn.channel.send(conn.io, packet);
                },
                .rtcp => {
                    var it = read_result.rtcp;
                    while (it.next() catch continue) |packet| {
                        std.debug.print("[{}]: {s}", .{ packet.@"0", @tagName(packet.@"1".header.payload_type) });
                    }
                },
                else => {},
            }

            conn.handle(now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        }
    }

    fn onTimeout(conn: *PublisherConnection) !void {
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

    fn handle(conn: *PublisherConnection, now: i64) !void {
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

const ViewerConnection = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    publisher: *PublisherConnection,
    done: std.Io.Event,
    connected: std.Io.Event,
    send_buffer: [1500]u8,
    recv_buffer: [1500]u8,
    mutex: Io.Mutex,
    prng: std.Random.DefaultCsprng,
    sender_id: u32,

    const Config = struct {
        media_engine: *webrtc.MediaEngine,
        publisher: *PublisherConnection,
    };

    fn init(conn: *ViewerConnection, io: std.Io, allocator: std.mem.Allocator, config: Config) !void {
        var if_it = try ice.IfIterator.init(allocator, .{});
        defer if_it.deinit(allocator);

        const addr = if_it.next() orelse return error.NoNetworkInterface;
        const socket = try addr.bind(io, .{ .mode = .dgram });
        errdefer socket.close(io);

        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try io.randomSecure(&seed);
        conn.prng = std.Random.DefaultCsprng.init(seed);

        conn.pc = try .init(io, allocator, .{
            .media_engine = config.media_engine,
            .random = conn.prng.random(),
        });
        errdefer conn.pc.deinit();

        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        try conn.pc.addLocalCandidates(&.{socket.address}, now);

        conn.sender_id = try conn.pc.addTrack(.init(.video, conn.prng.random()), "stream");

        conn.io = io;
        conn.socket = socket;
        conn.done = .unset;
        conn.connected = .unset;
        conn.mutex = .init;
        conn.send_buffer = undefined;
        conn.recv_buffer = undefined;
        conn.publisher = config.publisher;
    }

    fn deinit(self: *ViewerConnection) void {
        self.socket.close(self.io);
        self.pc.deinit();
    }

    fn receive(conn: *ViewerConnection) !void {
        while (true) {
            const inc = conn.socket.receive(conn.io, &conn.recv_buffer) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };

            try conn.mutex.lock(conn.io);
            defer conn.mutex.unlock(conn.io);

            const now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            const read_result = conn.pc.handleRead(.{
                .data = inc.data,
                .from = &inc.from,
                .to = &conn.socket.address,
            }, now) catch continue;

            if (read_result == .rtcp) {
                var it = read_result.rtcp;
                while (it.next() catch continue) |rtcp_packet| {
                    _, const packet = rtcp_packet;

                    switch (packet.payload) {
                        .pli => conn.publisher.sendPli() catch {},
                        else => {},
                    }
                }
            }

            conn.handle(now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        }
    }

    fn onTimeout(conn: *ViewerConnection) !void {
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

    fn send(conn: *ViewerConnection, rtp_packet: *const rtp.Packet) !void {
        try conn.mutex.lock(conn.io);
        defer conn.mutex.unlock(conn.io);

        const sender = &conn.pc.transceivers.items[conn.sender_id].sender;
        const now = Io.Timestamp.now(conn.io, .awake).toMicroseconds();
        const msg = try sender.handleWrite(rtp_packet, &conn.send_buffer, now);
        try conn.socket.send(conn.io, msg.to, msg.data);
    }

    fn handle(conn: *ViewerConnection, now: i64) !void {
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
    const io = init.io;
    const allocator = init.gpa;

    var grp: Io.Group = .init;
    defer grp.cancel(io);

    var memory_pool = try MemoryPool.initCapacity(allocator, 16);
    defer memory_pool.deinit(allocator);

    var media_engine = webrtc.MediaEngine.init(.{});
    try media_engine.registerDefaultCodecs(allocator);
    defer media_engine.deinit(allocator);

    var rtp_channel = BroadcastChannel.init(.{
        .deinit = deinitPacket,
        .deinit_ctx = &memory_pool,
        .empty = .{ .header = undefined, .payload = &.{} },
    });
    // No need for rtp_channel.deinit() since all the buffers will be released when the
    // memory is destroyed.

    var publisher: PublisherConnection = undefined;
    try publisher.init(io, allocator, .{
        .media_engine = &media_engine,
        .memory_pool = &memory_pool,
        .channel = &rtp_channel,
    });
    defer publisher.deinit();

    try grp.concurrent(io, startHttpServer, .{ io, allocator });
    try grp.concurrent(io, PublisherConnection.receive, .{&publisher});
    try grp.concurrent(io, PublisherConnection.onTimeout, .{&publisher});
    try grp.concurrent(io, exit, .{ io, &publisher.done });

    {
        const offer = try queue.getOne(io);
        defer offer.deinit();

        _ = try publisher.pc.addTransceiverFromKind(.video, .{ .direction = .recvonly });
        try publisher.pc.setRemoteDescription(offer.value);

        const answer = try publisher.pc.createAnswer();
        try publisher.pc.setLocalDescription(answer);
    }

    try common.utils.writeSdpToStdout(io, allocator, &publisher.pc);

    var viewers: std.ArrayList(*ViewerConnection) = .empty;
    defer {
        for (viewers.items) |viewer| {
            viewer.deinit();
            allocator.destroy(viewer);
        }
        viewers.deinit(allocator);
    }

    while (queue.getOne(io)) |offer| {
        defer offer.deinit();

        try viewers.ensureUnusedCapacity(allocator, 1);
        var viewer = try allocator.create(ViewerConnection);
        errdefer allocator.destroy(viewer);

        try viewer.init(io, allocator, .{
            .media_engine = &media_engine,
            .publisher = &publisher,
        });
        errdefer viewer.deinit();

        try viewer.pc.setRemoteDescription(offer.value);
        const answer = try viewer.pc.createAnswer();
        try viewer.pc.setLocalDescription(answer);

        try grp.concurrent(io, ViewerConnection.receive, .{viewer});
        try grp.concurrent(io, ViewerConnection.onTimeout, .{viewer});
        try grp.concurrent(io, sendDataToSubscriber, .{ viewer, &rtp_channel });

        try common.utils.writeSdpToStdout(io, allocator, &viewer.pc);
        viewers.appendAssumeCapacity(viewer);
    } else |_| {}
}

fn exit(io: Io, done: *Io.Event) !void {
    try done.wait(io);
    queue.close(io);
}

fn deinitPacket(userdata: ?*anyopaque, packet: *rtp.Packet) void {
    if (packet.payload.len == 0) return;
    const c: *MemoryPool = @ptrCast(@alignCast(userdata.?));
    c.destroy(@ptrCast(@alignCast(@constCast(packet.payload))));
}

fn clonePacket(userdata: ?*anyopaque, packet: *const rtp.Packet) rtp.Packet {
    const buffer: *[1500]u8 = @ptrCast(@alignCast(userdata.?));
    @memcpy(buffer.*[0..packet.payload.len], packet.payload);
    return .{
        .header = packet.header,
        .payload = buffer.*[0..packet.payload.len],
    };
}

fn startHttpServer(io: Io, allocator: std.mem.Allocator) !void {
    var grp: Io.Group = .init;
    defer grp.cancel(io);

    var server = server_addr.listen(io, .{ .mode = .stream, .reuse_address = true }) catch |err| {
        std.log.err("Error while starting http server: {}", .{err});
        return;
    };
    defer server.deinit(io);

    std.log.info("Http server started listening on port 9000...", .{});

    while (server.accept(io)) |client_socket| {
        try handleClientConnection(io, allocator, client_socket);
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("Error while accepting client connection: {}", .{err}),
    }
}

fn handleClientConnection(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream) !void {
    doHandleClientConnection(io, allocator, stream) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

fn doHandleClientConnection(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream) !void {
    defer stream.close(io);

    var in_buffer: [1024]u8 = undefined;
    var out_buffer: [1024]u8 = undefined;

    var r = stream.reader(io, &in_buffer);
    var w = stream.writer(io, &out_buffer);

    var http_server = std.http.Server.init(&r.interface, &w.interface);
    var req = try http_server.receiveHead();

    if (req.head.method == .POST) {
        const parsed = readRequestContent(allocator, &req) catch |err| switch (err) {
            error.ReadFailed => return r.err.?,
            else => |e| return e,
        };

        try queue.putOne(io, parsed);
        try req.respond(&.{}, .{ .transfer_encoding = .none, .status = .ok });
    }
}

fn readRequestContent(allocator: std.mem.Allocator, req: *std.http.Server.Request) !std.json.Parsed(webrtc.SessionDescription) {
    const base64_offer = try allocator.alloc(u8, req.head.content_length.?);
    defer allocator.free(base64_offer);

    var reader = req.readerExpectNone(&.{});
    try reader.readSliceAll(base64_offer);

    const offer_len = try std.base64.standard.Decoder.calcSizeForSlice(base64_offer);
    const offer = try allocator.alloc(u8, offer_len);
    defer allocator.free(offer);
    try std.base64.standard.Decoder.decode(offer, base64_offer);
    return try std.json.parseFromSlice(webrtc.SessionDescription, allocator, offer, .{});
}

fn sendDataToSubscriber(viewer: *ViewerConnection, c: *BroadcastChannel) !void {
    try viewer.connected.wait(viewer.io);

    var buffer: [1500]u8 = undefined;
    var sub = c.subscribe(clonePacket, &buffer);

    while (c.receive(viewer.io, &sub)) |packet| {
        viewer.send(&packet) catch return;
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("Error while receiving data from broadcast channel: {}", .{err}),
    }
}
