//! Multi-pair data-channel flow-control benchmark.
//!
//! Spawns `FLOW_PAIRS` in-process connection pairs, each running the unordered/no-retransmit or ordered/reliable,
//! 1 KB / 512 KB-1 MB-watermark, `bufferedAmount`-flow-controlled transfer of the stock
//! `data-channels-flow-control` example. Each pair skips `FLOW_WARMUP_MB` of ramp, then
//! measures per-interval steady-state throughput over `FLOW_STOP_MB`; once every pair has
//! finished its measured window the process prints an aggregate `FINAL` line and exits.
//!
//! FLOW_PAIRS=10 FLOW_WARMUP_MB=64 FLOW_STOP_MB=128 FLOW_ORDERED=1 ./data_channels_flow_control_multi

const std = @import("std");
const webrtc = @import("webrtc");

const Io = std.Io;

pub const std_options = std.Options{ .log_level = .info };

var aggregate: std.atomic.Value(f64) = .init(0);

const max_datagram_size = 1500;
const buffered_amount_low_threshold: u32 = 512 * 1024; // 512 KiB
const buffered_amount_high_threshold: u32 = 1024 * 1024; // 1 MiB
const buffer: [1024]u8 = @splat(0xff);
const rx_batch_size: usize = 32;
const tx_batch_size: usize = 32;

const Config = struct {
    flow_pairs: u16,
    flow_warmup: u32,
    flow_stop: u32,
    ordered: bool,

    fn fromEnvMap(env: std.process.Environ, allocator: std.mem.Allocator) !Config {
        var map = try env.createMap(allocator);
        defer map.deinit();

        var config: Config = undefined;
        config.flow_pairs = try std.fmt.parseInt(u16, map.get("FLOW_PAIRS") orelse "1", 10);
        config.flow_warmup = try std.fmt.parseInt(u32, map.get("FLOW_WARMUP_MB") orelse "64", 10) *| 1024 *| 1024;
        config.flow_stop = try std.fmt.parseInt(u32, map.get("FLOW_STOP_MB") orelse "128", 10) *| 1024 *| 1024;
        config.ordered = if (map.get("FLOW_ORDERED")) |v| !std.mem.eql(u8, v, "0") else false;
        return config;
    }
};

const SenderContext = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    prng: std.Random.DefaultCsprng,
    dc: webrtc.DataChannel,
    pool: std.heap.MemoryPool([max_datagram_size]u8),
    queue_buffer: [tx_batch_size]webrtc.TransportMessage,
    send_queue: Io.Queue(webrtc.TransportMessage),
    mutex: Io.Mutex,

    fn init(conn: *SenderContext, io: std.Io, allocator: std.mem.Allocator, media_engine: *webrtc.MediaEngine, ordered: bool) !void {
        const addr = Io.net.IpAddress{ .ip4 = .loopback(0) };
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

        conn.dc = try conn.pc.createDataChannel("zig-test", .{
            .ordered = ordered,
            .max_retransmits = if (ordered) null else 0,
        });
        try conn.dc.setBufferedAmountLowThreshold(buffered_amount_low_threshold);

        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        try conn.pc.addLocalCandidates(&.{socket.address}, now);
        try conn.pc.addLocalCandidates(&.{}, now);

        conn.io = io;
        conn.socket = socket;
        conn.pool = (try .initCapacity(allocator, tx_batch_size));
        conn.queue_buffer = undefined;
        conn.send_queue = .init(&conn.queue_buffer);
        conn.mutex = .init;
    }

    fn deinit(self: *SenderContext) void {
        self.socket.close(self.io);
        self.pool.deinit(self.pc.allocator);
        self.pc.deinit();
    }

    fn start(conn: *SenderContext) Io.Cancelable!void {
        var recv_buffer: [max_datagram_size]u8 = undefined;
        var now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
        while (true) {
            conn.handle(now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    std.log.err("Failed to handle connection: {}", .{err});
                    return;
                },
            };

            const deadline = conn.pc.pollTimeout();
            // The poll timeout is truncated to whole milliseconds, wait one more millisecond so
            // the receive doesn't time out before the deadline and spin until it's reached.
            const timeout = if (deadline) |d| Io.Timeout{ .deadline = .{
                .raw = .fromNanoseconds((d + 1) * std.time.ns_per_ms),
                .clock = .awake,
            } } else Io.Timeout{ .none = {} };

            const datagram = conn.socket.receiveTimeout(conn.io, &recv_buffer, timeout) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => null,
                else => {
                    std.log.err("Failed to receive datagram: {}", .{err});
                    return;
                },
            };

            now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            if (datagram) |inc| switch (conn.pc.handleRead(.{
                .data = inc.data,
                .from = &inc.from,
                .to = &conn.socket.address,
            }, now) catch |err| {
                std.log.err("Failed to handle incoming datagram: {}", .{err});
                return;
            }) {
                .app_data => |it| {
                    var it2 = it;
                    while (it2.next() catch return) |_| {}
                },
                else => {},
            };

            const expired = if (deadline) |d| now >= d else false;
            if (datagram == null or expired) {
                conn.pc.handleTimeout(now, 0) catch |err| {
                    std.log.err("Failed to handle timeout: {}", .{err});
                    return;
                };
            }
        }
    }

    fn handle(conn: *SenderContext, now: i64) !void {
        while (conn.pc.pollEvent()) |event| switch (event) {
            .connection_state => |state| switch (state) {
                .closed, .failed => return error.ConnectionFailed,
                else => {},
            },
            .data_channel => |dc_event| switch (dc_event) {
                .open => try conn.sendData(),
                .buffered_amount_low_threshold => try conn.sendData(),
                else => {},
            },
            else => {},
        };

        var messages: [8]webrtc.TransportMessage = undefined;
        var count: u8 = 0;

        while (true) {
            const buf = try conn.getBuffer();
            messages[count] = try conn.pc.pollTransmit(buf, now) orelse {
                try conn.freeBuffer(buf);
                if (count > 0) try conn.send_queue.putAll(conn.io, messages[0..count]);
                break;
            };
            count += 1;
            if (count == messages.len) {
                count = 0;
                try conn.send_queue.putAll(conn.io, &messages);
            }
        }
    }

    fn send(conn: *SenderContext) !void {
        var messages: [tx_batch_size]webrtc.TransportMessage = undefined;
        while (true) {
            const count = conn.send_queue.get(conn.io, &messages, 1) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };

            for (messages[0..count]) |msg| while (true) {
                conn.socket.send(conn.io, msg.to, msg.data) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => continue,
                };
                break;
            };

            try conn.mutex.lock(conn.io);
            defer conn.mutex.unlock(conn.io);
            for (messages[0..count]) |msg| conn.pool.destroy(@ptrCast(@alignCast(@constCast(msg.data))));
        }
    }

    fn sendData(conn: *SenderContext) !void {
        var buffered: usize = conn.dc.bufferedAmount();
        while (buffer.len + buffered <= buffered_amount_high_threshold) : (buffered += buffer.len) {
            try conn.dc.send(&buffer, 0); // we use ordered or max_retransmit, so the timestamp is not needed
        }
    }

    fn getBuffer(conn: *SenderContext) ![]u8 {
        try conn.mutex.lock(conn.io);
        defer conn.mutex.unlock(conn.io);
        return try conn.pool.create(conn.pc.allocator);
    }

    fn freeBuffer(conn: *SenderContext, buf: []u8) !void {
        try conn.mutex.lock(conn.io);
        defer conn.mutex.unlock(conn.io);
        conn.pool.destroy(@ptrCast(@alignCast(@constCast(buf))));
    }
};

const ReceiverContext = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    send_buffer: [max_datagram_size]u8,
    prng: std.Random.DefaultCsprng,
    received: u64,
    config: Config,
    measure_start: ?i64,
    measure_start_bytes: u64,
    done: Io.Event,

    fn init(
        conn: *ReceiverContext,
        io: std.Io,
        allocator: std.mem.Allocator,
        media_engine: *webrtc.MediaEngine,
        config: Config,
    ) !void {
        const addr = Io.net.IpAddress{ .ip4 = .loopback(0) };
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

        conn.io = io;
        conn.socket = socket;
        conn.send_buffer = undefined;
        conn.received = 0;
        conn.config = config;
        conn.measure_start = null;
        conn.measure_start_bytes = 0;
        conn.done = .unset;
    }

    fn deinit(self: *ReceiverContext) void {
        self.socket.close(self.io);
        self.pc.deinit();
    }

    fn start(conn: *ReceiverContext) Io.Cancelable!void {
        var recv_buffer: [rx_batch_size * max_datagram_size]u8 = undefined;
        var messages: [rx_batch_size]Io.net.IncomingMessage = undefined;

        var now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
        while (true) {
            conn.handle(now) catch |err| {
                std.log.err("Failed to handle connection: {}", .{err});
                return;
            };

            const deadline = conn.pc.pollTimeout();
            const timeout: Io.Timeout = if (deadline) |d| .{
                .deadline = .{
                    .raw = .fromNanoseconds((d + 1) * std.time.ns_per_ms),
                    .clock = .awake,
                },
            } else .none;

            const maybe_err, const count = conn.socket.receiveManyTimeout(
                conn.io,
                &messages,
                &recv_buffer,
                .{},
                timeout,
            );

            if (count == 0) if (maybe_err) |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => {},
                else => {
                    std.log.err("Failed to receive datagrams: {}", .{err});
                    return;
                },
            };

            now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            for (0..count) |idx| {
                const msg = webrtc.TransportMessage{
                    .data = messages[idx].data,
                    .from = &messages[idx].from,
                    .to = &conn.socket.address,
                };
                const result = conn.pc.handleRead(msg, now) catch |err| {
                    std.log.err("Failed to handle incoming datagram: {}", .{err});
                    return;
                };

                if (result == .app_data) {
                    var it = result.app_data;
                    while (it.next() catch return) |message| {
                        conn.received += message.data.len;
                        if (conn.measure_start == null and conn.received >= conn.config.flow_warmup) {
                            conn.measure_start = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
                            conn.measure_start_bytes = conn.received;
                        } else if (conn.measure_start != null and conn.received - conn.measure_start_bytes >= conn.config.flow_stop) {
                            now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
                            const elapsed = @as(f64, @floatFromInt(now - conn.measure_start.?)) / 1000;
                            const bytes_received = conn.received - conn.measure_start_bytes;
                            const throughput = @as(f64, @floatFromInt(bytes_received * 8)) / elapsed / 1024 / 1024;
                            _ = aggregate.fetchAdd(throughput, .monotonic);
                            conn.done.set(conn.io);
                            return;
                        }
                    }
                }
            }

            const expired = if (deadline) |d| now >= d else false;
            if (count == 0 or expired) {
                conn.pc.handleTimeout(now, 0) catch |err| {
                    std.log.err("Failed to handle timeout: {}", .{err});
                    return;
                };
            }
        }
    }

    fn handle(conn: *ReceiverContext, now: i64) !void {
        while (conn.pc.pollEvent()) |event| switch (event) {
            .connection_state => |state| switch (state) {
                .closed, .failed => return error.ConnectionFailed,
                else => {},
            },
            else => {},
        };

        while (try conn.pc.pollTransmit(&conn.send_buffer, now)) |message| while (true) {
            conn.socket.send(conn.io, message.to, message.data) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            break;
        };
    }
};

fn runPair(io: Io, allocator: std.mem.Allocator, media_engine: *webrtc.MediaEngine, config: Config) !void {
    innerRunPair(io, allocator, media_engine, config) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            std.log.err("Failed to run pair: {}", .{e});
            return;
        },
    };
}

fn innerRunPair(io: Io, allocator: std.mem.Allocator, media_engine: *webrtc.MediaEngine, config: Config) !void {
    var offerer: SenderContext = undefined;
    try offerer.init(io, allocator, media_engine, config.ordered);
    defer offerer.deinit();

    var answerer: ReceiverContext = undefined;
    try answerer.init(io, allocator, media_engine, config);
    defer answerer.deinit();

    var grp: Io.Group = .init;
    defer grp.cancel(io);

    const now = Io.Timestamp.now(io, .awake).toMilliseconds();
    const offer = try offerer.pc.createOffer();
    try offerer.pc.setLocalDescription(offer);
    try answerer.pc.setRemoteDescription(offer, now);

    const answer = try answerer.pc.createAnswer();
    try answerer.pc.setLocalDescription(answer);
    try offerer.pc.setRemoteDescription(answer, now);

    try grp.concurrent(io, SenderContext.start, .{&offerer});
    try grp.concurrent(io, SenderContext.send, .{&offerer});
    try grp.concurrent(io, ReceiverContext.start, .{&answerer});

    try answerer.done.wait(io);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var grp: Io.Group = .init;
    defer grp.cancel(io);

    const config: Config = try .fromEnvMap(init.minimal.environ, allocator);

    var media_engine = webrtc.MediaEngine.init(.{});
    defer media_engine.deinit(allocator);

    const start = Io.Timestamp.now(io, .awake).toMilliseconds();

    for (0..config.flow_pairs) |_| {
        try grp.concurrent(io, runPair, .{ io, allocator, &media_engine, config });
    }
    try grp.await(io);

    const elapsed = Io.Timestamp.now(io, .awake).toMilliseconds() - start;

    std.debug.print("FINAL {:.3} Mbps over {} pairs (ordered={}) in {:.3}s\n", .{
        aggregate.raw,
        config.flow_pairs,
        config.ordered,
        @as(f64, @floatFromInt(elapsed)) / 1000,
    });
}
