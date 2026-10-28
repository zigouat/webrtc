const std = @import("std");
const webrtc = @import("webrtc");
const common = @import("common");
const ice = @import("ice");

const Io = std.Io;

pub const std_options = std.Options{ .log_level = .info };

var grp: Io.Group = .init;

const max_datagram_size = 1500;
const buffered_amout_low_threshold: u32 = 512 * 1024; // 512 KiB
const max_buffered_amount: u32 = 1024 * 1024; // 1 MiB
const buffer: [1024]u8 = @splat(0xff);

const ConnectionContext = struct {
    io: std.Io,
    pc: webrtc.PeerConnection,
    socket: std.Io.net.Socket,
    buffers: [max_datagram_size * 2]u8,
    prng: std.Random.DefaultCsprng,
    dc: webrtc.DataChannel,
    offerer: bool,
    received: u64,

    fn init(conn: *ConnectionContext, io: std.Io, allocator: std.mem.Allocator, media_engine: *webrtc.MediaEngine, offerer: bool) !void {
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

        if (offerer) {
            conn.dc = try conn.pc.createDataChannel("zig-test", .{ .ordered = false });
            try conn.dc.setBufferedAmountLowThreshold(buffered_amout_low_threshold);
        }

        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        try conn.pc.addLocalCandidates(&.{socket.address}, now);
        try conn.pc.addLocalCandidates(&.{}, now);

        conn.io = io;
        conn.socket = socket;
        conn.buffers = undefined;
        conn.offerer = offerer;
        conn.received = 0;
    }

    fn deinit(self: *ConnectionContext) void {
        self.socket.close(self.io);
        self.pc.deinit();
    }

    fn start(conn: *ConnectionContext) Io.Cancelable!void {
        var now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
        while (true) {
            conn.handle(now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };

            const deadline = conn.pc.pollTimeout();
            // The poll timeout is truncated to whole milliseconds, wait one more millisecond so
            // the receive doesn't time out before the deadline and spin until it's reached.
            const timeout = if (deadline) |d| Io.Timeout{ .deadline = .{
                .raw = .fromNanoseconds((d + 1) * std.time.ns_per_ms),
                .clock = .awake,
            } } else Io.Timeout{ .none = {} };

            const datagram = conn.socket.receiveTimeout(conn.io, conn.buffers[0..max_datagram_size], timeout) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => null,
                else => {
                    std.log.err("Failed to receive datagram: {}", .{err});
                    return;
                },
            };

            now = Io.Timestamp.now(conn.io, .awake).toMilliseconds();
            if (datagram) |inc| {
                const result = conn.pc.handleRead(.{
                    .data = inc.data,
                    .from = &inc.from,
                    .to = &conn.socket.address,
                }, now) catch |err| {
                    std.log.err("Failed to handle incoming datagram: {}", .{err});
                    return;
                };

                switch (result) {
                    .app_data => |it| {
                        var it2 = it;
                        while (it2.next() catch return) |message| {
                            defer conn.pc.allocator.free(message.data);
                            conn.received += message.data.len;
                        }
                    },
                    else => {},
                }
            }

            const expired = if (deadline) |d| now >= d else false;
            if (datagram == null or expired) {
                conn.pc.handleTimeout(now, 0) catch |err| {
                    std.log.err("Failed to handle timeout: {}", .{err});
                    return;
                };
            }
        }
    }

    fn handle(conn: *ConnectionContext, now: i64) !void {
        while (conn.pc.pollEvent()) |event| switch (event) {
            .connection_state => |state| switch (state) {
                .closed, .failed => return error.ConnectionFailed,
                else => {},
            },
            .data_channel => |dc_event| switch (dc_event) {
                .new => |id| conn.dc = conn.pc.getDataChannel(id),
                .open => if (conn.offerer) try conn.sendData(),
                // The answerer's threshold is 0, the event fires once its DCEP ack is sent.
                .buffered_amount_low_threshold => if (conn.offerer) try conn.sendData(),
                else => {},
            },
            else => {},
        };

        while (try conn.pc.pollTransmit(conn.buffers[max_datagram_size..], now)) |message| {
            conn.socket.send(conn.io, message.to, message.data) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // A failed UDP send is just a lost packet (e.g. EPERM from netfilter), the peers recover from it.
                else => std.log.warn("Failed to send datagram to {f}: {}", .{ message.to, err }),
            };
        }
    }

    fn sendData(conn: *ConnectionContext) !void {
        var buffered = conn.dc.bufferedAmount();
        while (buffer.len + buffered <= max_buffered_amount) : (buffered += buffer.len) {
            try conn.dc.send(&buffer);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    defer grp.cancel(io);

    var media_engine = webrtc.MediaEngine.init(.{});
    defer media_engine.deinit(init.gpa);

    var offerer: ConnectionContext = undefined;
    try offerer.init(io, init.gpa, &media_engine, true);
    defer offerer.deinit();

    var answerer: ConnectionContext = undefined;
    try answerer.init(io, init.gpa, &media_engine, false);
    defer answerer.deinit();

    const now = Io.Timestamp.now(io, .awake).toMilliseconds();

    const offer = try offerer.pc.createOffer();
    try offerer.pc.setLocalDescription(offer);
    try answerer.pc.setRemoteDescription(offer, now);

    const answer = try answerer.pc.createAnswer();
    try answerer.pc.setLocalDescription(answer);
    try offerer.pc.setRemoteDescription(answer, now);

    try grp.concurrent(io, ConnectionContext.start, .{&offerer});
    try grp.concurrent(io, ConnectionContext.start, .{&answerer});
    try grp.concurrent(io, reportThroughput, .{ io, &answerer });

    try grp.await(io);
}

fn reportThroughput(io: std.Io, ctx: *ConnectionContext) !void {
    var last_report_time = Io.Timestamp.now(io, .awake).toMilliseconds();
    var last_received = ctx.received;

    while (true) {
        try io.sleep(.fromSeconds(1), .awake);
        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        const elapsed = now - last_report_time;
        const received = ctx.received - last_received;

        const throughput_kbps = (received * 8) / @as(u64, @bitCast(elapsed)); // in kbps
        std.debug.print("Throughput: {d} Kbps\n", .{throughput_kbps});

        last_report_time = now;
        last_received = ctx.received;
    }
}
