const std = @import("std");
const webrtc = @import("webrtc");
const common = @import("common");
const ice = @import("ice");

const Io = std.Io;

pub const std_options = std.Options{ .log_level = .info };

var grp: Io.Group = .init;

const ConnectionContext = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    done: std.Io.Event,
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

    fn sendMessage(conn: *ConnectionContext, channel_id: webrtc.DataChannel.ChannelId) !void {
        var message: [20]u8 = @splat(0);

        while (true) {
            try conn.io.sleep(.fromSeconds(5), .awake);
            common.utils.randString(conn.io, &message);
            conn.pc.sendDataChannelMessage(channel_id, &message) catch return;
        }
    }

    fn handle(conn: *ConnectionContext, now: i64) !void {
        while (conn.pc.pollEvent()) |event| switch (event) {
            .connection_state => |state| switch (state) {
                .disconnected, .closed, .failed => conn.done.set(conn.io),
                else => {},
            },
            .data_channel => |dc_event| switch (dc_event) {
                .new => |id| std.log.info("New data channel: {}", .{id}),
                .open => |id| {
                    std.log.info("Data channel open: {}", .{id});
                    try grp.concurrent(conn.io, sendMessage, .{ conn, id });
                },
                .close => |id| std.log.info("Data channel closed: {}", .{id}),
                .message => |msg| std.debug.print("[{}]: {s}\n", .{ msg.channel_id, msg.data }),
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
    defer grp.cancel(io);

    var media_engine = webrtc.MediaEngine.init(.{});
    defer media_engine.deinit(init.gpa);

    var conn: ConnectionContext = undefined;
    try conn.init(io, init.gpa, &media_engine);
    defer conn.deinit();

    const offer = try common.utils.readSdpFromStdin(io, init.gpa);
    defer offer.deinit();

    try conn.pc.setRemoteDescription(offer.value);
    const answer = try conn.pc.createAnswer();
    try conn.pc.setLocalDescription(answer);

    try common.utils.writeSdpToStdout(io, init.gpa, &conn.pc);

    try grp.concurrent(io, ConnectionContext.receive, .{&conn});
    try grp.concurrent(io, ConnectionContext.onTimeout, .{&conn});

    try conn.done.wait(io);
}
