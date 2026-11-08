const std = @import("std");
const webrtc = @import("webrtc");
const common = @import("common");
const ice = @import("ice");

const Io = std.Io;

pub const std_options = std.Options{ .log_level = .info };

const ConnectionContext = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    done: std.Io.Event,
    gathered: std.Io.Event,
    send_buffer: [1500]u8,
    recv_buffer: [1500]u8,
    prng: std.Random.DefaultCsprng,
    audio_sender: webrtc.RtpSender,
    video_sender: webrtc.RtpSender,

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
        try conn.pc.addLocalCandidates(&.{}, now);

        conn.video_sender = try conn.pc.addTrack(.initWithId("video", .video), "my-stream");
        conn.audio_sender = try conn.pc.addTrack(.initWithId("audio", .audio), "my-stream");

        conn.io = io;
        conn.socket = socket;
        conn.done = .unset;
        conn.gathered = .unset;
        conn.send_buffer = undefined;
        conn.recv_buffer = undefined;
    }

    fn deinit(self: *ConnectionContext) void {
        self.socket.close(self.io);
        self.pc.deinit();
    }

    fn onReceive(conn: *ConnectionContext) !void {
        var now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
        while (true) {
            conn.handle(now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };

            const deadline = conn.pc.pollTimeout();
            const timeout = if (deadline) |d|
                Io.Timeout{ .deadline = .{ .raw = .fromNanoseconds((d + 1) * std.time.ns_per_ms), .clock = .awake } }
            else
                .none;

            const inc = conn.socket.receiveTimeout(conn.io, &conn.recv_buffer, timeout) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => null,
                else => return,
            };

            now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            if (inc) |in| {
                const read_result = conn.pc.handleRead(.{
                    .data = in.data,
                    .from = &in.from,
                    .to = &conn.socket.address,
                }, now) catch continue;

                switch (read_result) {
                    .rtp => |received| {
                        const receiver = received.@"0";
                        const sender = if (receiver.getTrack().kind == .video) conn.video_sender else conn.audio_sender;

                        const now_us = Io.Timestamp.now(conn.io, .awake).toMicroseconds();
                        const msg = sender.sendRtp(
                            &received.@"1",
                            &conn.send_buffer,
                            now_us,
                        ) catch continue;
                        conn.socket.send(conn.io, msg.to, msg.data) catch |err| switch (err) {
                            error.Canceled => return error.Canceled,
                            else => {},
                        };
                    },
                    else => {},
                }
            }

            if (inc == null or (deadline != null and now >= deadline.?)) {
                conn.pc.handleTimeout(now, Io.Timestamp.now(conn.io, .awake).toMicroseconds()) catch |err| {
                    std.log.err("Error handling timeout: {}", .{err});
                    return;
                };
            }
        }
    }

    fn handle(conn: *ConnectionContext, now: i64) !void {
        while (conn.pc.pollEvent()) |event| switch (event) {
            .connection_state => |state| {
                std.log.info("Peer Connection State has changed: {t}", .{state});
                switch (state) {
                    .disconnected, .closed, .failed => conn.done.set(conn.io),
                    else => {},
                }
            },
            .track => |ev| std.log.info("Track has started, of type {t}", .{ev.track.kind}),
            .gathering_state => |state| if (state == .complete) conn.gathered.set(conn.io),
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

    var media_engine = webrtc.MediaEngine.init(.{});
    try media_engine.registerDefaultCodecs(allocator);
    defer media_engine.deinit(allocator);

    var conn: ConnectionContext = undefined;
    try conn.init(io, allocator, &media_engine);
    defer conn.deinit();

    const offer = try common.utils.readSdpFromStdin(io, init.gpa);
    defer offer.deinit();

    const now = Io.Timestamp.now(io, .awake).toMilliseconds();
    try conn.pc.setRemoteDescription(offer.value, now);
    const answer = try conn.pc.createAnswer();
    defer conn.pc.allocator.free(answer.sdp);
    try conn.pc.setLocalDescription(answer);

    try grp.concurrent(io, ConnectionContext.onReceive, .{&conn});
    try conn.gathered.wait(io);
    try common.utils.writeSdpToStdout(io, init.gpa, &conn.pc);
    try conn.done.wait(io);
}
