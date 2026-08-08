const std = @import("std");
const webrtc = @import("webrtc");
const media = @import("media");
const rtp = @import("rtp");

const Io = std.Io;
const BroadcastChannel = media.BroadcastChannel(rtp.Packet, 16);

const server_addr = Io.net.IpAddress{ .ip4 = .unspecified(9000) };
var queue_buffer: [1]std.json.Parsed(webrtc.SessionDescription) = undefined;
var queue: Io.Queue(std.json.Parsed(webrtc.SessionDescription)) = .init(&queue_buffer);

pub const std_options = std.Options{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var grp: Io.Group = .init;
    defer grp.cancel(io);

    try grp.concurrent(io, startHttpServer, .{ io, allocator });

    // start publisher
    const pc, const tr, var rtp_channel = blk: {
        const offer = try queue.getOne(io);
        defer offer.deinit();

        var pc = try allocator.create(webrtc.PeerConnection);
        pc.* = try .init(io, allocator, .{});
        errdefer {
            pc.deinit();
            allocator.destroy(pc);
        }

        const tr = try pc.addTransceiverFromKind(.video, .{ .direction = .recvonly });
        try pc.setRemoteDescription(offer.value);

        const answer = try pc.createAnswer();
        try pc.setLocalDescription(answer);

        const rtp_channel = BroadcastChannel.init(.{
            .deinit = deinitPacket,
            .deinit_ctx = &tr.receiver,
            .empty = .{ .header = undefined, .payload = &.{} },
        });
        break :blk .{ pc, tr, rtp_channel };
    };
    // No need for rtp_channel.deinit() since all the buffers will be released when the
    // ice agent is destroyed.

    var gathering_done = Io.Event.unset;
    var done = Io.Event.unset;

    try grp.concurrent(io, exit, .{ io, &done });
    try grp.concurrent(io, pollPublisher, .{ io, pc, &gathering_done, &done });
    try pc.group.concurrent(io, receivePublishedData, .{ io, &tr.receiver, &rtp_channel });

    try gathering_done.wait(io);
    try encodeSdp(pc);

    while (queue.getOne(io)) |offer| {
        defer offer.deinit();

        const pc2 = try allocator.create(webrtc.PeerConnection);
        pc2.* = try .init(io, allocator, .{});
        errdefer {
            pc2.deinit();
            allocator.destroy(pc2);
        }

        const sender = try pc2.addTrack(.init(io, .video), "stream");
        gathering_done.reset();
        try grp.concurrent(io, pollSubscriber, .{ io, pc2, sender, &gathering_done, &rtp_channel });
        try pc2.setRemoteDescription(offer.value);

        const answer = try pc2.createAnswer();
        try pc2.setLocalDescription(answer);

        try gathering_done.wait(io);
        try encodeSdp(pc2);
    } else |_| {}
}

fn exit(io: Io, done: *Io.Event) !void {
    try done.wait(io);
    queue.close(io);
}

fn deinitPacket(userdata: ?*anyopaque, packet: *rtp.Packet) void {
    if (packet.payload.len == 0) return;
    const receiver: *webrtc.RtpReceiver = @ptrCast(@alignCast(userdata.?));
    receiver.deinitEvent(&.{ .rtp = packet.* });
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

fn encodeSdp(pc: *webrtc.PeerConnection) !void {
    var sdp = (try pc.getLocalDescription()).?;
    defer sdp.deinit(pc.allocator);

    var w = Io.Writer.Allocating.init(pc.allocator);
    defer w.deinit();

    const formatter = std.json.fmt(sdp, .{});
    try formatter.format(&w.writer);

    const sdp_len = std.base64.standard.Encoder.calcSize(w.written().len);
    const base64_sdp = try pc.allocator.alloc(u8, sdp_len);
    defer pc.allocator.free(base64_sdp);

    const result = std.base64.standard.Encoder.encode(base64_sdp, w.written());
    std.debug.print("{s}\n", .{result});
}

fn pollPublisher(io: Io, pc: *webrtc.PeerConnection, gathering_done: *Io.Event, done: *Io.Event) !void {
    defer pc.allocator.destroy(pc);
    defer pc.deinit();

    while (pc.poll()) |event| switch (event) {
        .connection_state => |state| {
            std.log.info("Publisher state: {}", .{state});
            switch (state) {
                .connected => {
                    // send pli periodically to the publisher to request keyframes
                    pc.group.concurrent(io, sendPli, .{ io, &pc.getTransceivers()[0].receiver }) catch return;
                },
                .failed => {
                    pc.close();
                    done.set(io);
                },
                .closed => {
                    done.set(io);
                    break;
                },
                else => {},
            }
        },
        .gathering_state => |state| if (state == .complete) gathering_done.set(io),
        else => {},
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("Error while polling publisher: {}", .{err}),
    }
}

fn receivePublishedData(io: Io, receiver: *webrtc.RtpReceiver, c: *BroadcastChannel) !void {
    while (receiver.poll(io)) |event| switch (event) {
        .rtp => |packet| c.send(io, packet),
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("Error while polling receiver: {}", .{err}),
    }
}

fn sendPli(io: Io, receiver: *webrtc.RtpReceiver) !void {
    while (true) {
        try io.sleep(.fromSeconds(3), .awake);
        receiver.sendPli() catch return;
    }
}

fn pollSubscriber(
    io: Io,
    pc: *webrtc.PeerConnection,
    sender: *webrtc.RtpSender,
    gathering_done: *Io.Event,
    c: *BroadcastChannel,
) !void {
    defer pc.allocator.destroy(pc);
    defer pc.deinit();

    while (pc.poll()) |event| switch (event) {
        .connection_state => |state| switch (state) {
            .connected => pc.group.concurrent(io, sendDataToSubscriber, .{ io, sender, c }) catch return,
            .failed => pc.close(),
            .closed => break,
            else => {},
        },
        .gathering_state => |state| if (state == .complete) gathering_done.set(io),
        else => {},
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("Error while polling publisher: {}", .{err}),
    }
}

fn sendDataToSubscriber(io: Io, sender: *webrtc.RtpSender, c: *BroadcastChannel) !void {
    var buffer: [1500]u8 = undefined;
    var sub = c.subscribe(clonePacket, &buffer);

    while (c.receive(io, &sub)) |packet| {
        sender.sendRtp(&packet) catch return;
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("Error while receiving data from broadcast channel: {}", .{err}),
    }
}
