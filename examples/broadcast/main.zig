const std = @import("std");
const webrtc = @import("webrtc");
const media = @import("media");
const rtp = @import("rtp");

const Io = std.Io;
const BroadcastChannel = media.BroadcastChannel(rtp.Packet, 16);
const MemoryPool = std.heap.MemoryPool([1500]u8);

const server_addr = Io.net.IpAddress{ .ip4 = .unspecified(9000) };
var queue_buffer: [1]std.json.Parsed(webrtc.SessionDescription) = undefined;
var queue: Io.Queue(std.json.Parsed(webrtc.SessionDescription)) = .init(&queue_buffer);

pub const std_options = std.Options{ .log_level = .info };

const PublisherHandler = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    grp: *Io.Group,
    gathering_done: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    channel: *BroadcastChannel,
    memory_pool: *MemoryPool,
    receiver: *webrtc.RtpReceiver = undefined,

    fn peerConnectionHandler(handler: *PublisherHandler) webrtc.PeerConnectionHandler {
        return .{
            .userdata = handler,
            .vtable = &.{
                .onGatheringStateChange = onGatheringStateChange,
                .onConnectionStateChange = onConnectionStateChange,
                .onTrack = onTrack,
            },
        };
    }

    fn onGatheringStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.GatheringState) void {
        const handler: *PublisherHandler = @ptrCast(@alignCast(userdata.?));
        if (state == .complete) handler.gathering_done.set(handler.io);
    }

    fn onConnectionStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.ConnectionState) void {
        std.log.info("Connection state changed: {s}", .{@tagName(state)});
        const handler: *PublisherHandler = @ptrCast(@alignCast(userdata.?));
        switch (state) {
            .connected => handler.grp.concurrent(handler.io, sendPli, .{
                handler.io,
                handler.receiver,
            }) catch @panic("ConcurrencyUnavailable"),
            .closed, .failed => handler.done.set(handler.io),
            else => {},
        }
    }

    fn onTrack(userdata: ?*anyopaque, event: webrtc.RtpTransceiver.TrackEventInit) void {
        const handler: *PublisherHandler = @ptrCast(@alignCast(userdata.?));
        std.log.info("New remote track({s}): {s}", .{ @tagName(event.track.kind), event.track.id });
        event.receiver.registerCallback(handler, receivePublishedData);
        handler.receiver = event.receiver;
    }
};

const ViewerHandler = struct {
    io: std.Io,
    grp: *Io.Group,
    gathering_done: std.Io.Event = .unset,
    channel: *BroadcastChannel,
    sender: *webrtc.RtpSender,

    fn peerConnectionHandler(handler: *ViewerHandler) webrtc.PeerConnectionHandler {
        return .{
            .userdata = handler,
            .vtable = &.{
                .onGatheringStateChange = onGatheringStateChange,
                .onConnectionStateChange = onConnectionStateChange,
            },
        };
    }

    fn onGatheringStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.GatheringState) void {
        const handler: *ViewerHandler = @ptrCast(@alignCast(userdata.?));
        if (state == .complete) handler.gathering_done.set(handler.io);
    }

    fn onConnectionStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.ConnectionState) void {
        std.log.info("Connection state changed: {s}", .{@tagName(state)});
        const handler: *ViewerHandler = @ptrCast(@alignCast(userdata.?));
        switch (state) {
            .connected => handler.grp.concurrent(handler.io, sendDataToSubscriber, .{
                handler.io,
                handler.sender,
                handler.channel,
            }) catch @panic("ConcurrencyUnavailable"),
            else => {},
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var grp: Io.Group = .init;
    defer grp.cancel(io);

    try grp.concurrent(io, startHttpServer, .{ io, allocator });

    var memory_pool = try MemoryPool.initCapacity(allocator, 16);
    defer memory_pool.deinit(allocator);

    var media_engine = webrtc.MediaEngine.init(.{});
    try media_engine.registerDefaultCodecs(allocator);
    defer media_engine.deinit(allocator);

    var publisher_handler = PublisherHandler{
        .io = io,
        .allocator = allocator,
        .grp = &grp,
        .channel = undefined,
        .memory_pool = &memory_pool,
    };

    // start publisher
    const pc = blk: {
        const offer = try queue.getOne(io);
        defer offer.deinit();

        var pc = try allocator.create(webrtc.PeerConnection);
        pc.* = try .init(io, allocator, .{
            .media_engine = &media_engine,
            .handler = publisher_handler.peerConnectionHandler(),
        });
        errdefer {
            pc.deinit();
            allocator.destroy(pc);
        }

        _ = try pc.addTransceiverFromKind(.video, .{ .direction = .recvonly });
        try pc.setRemoteDescription(offer.value);

        const answer = try pc.createAnswer();
        try pc.setLocalDescription(answer);

        break :blk pc;
    };
    defer {
        pc.deinit();
        allocator.destroy(pc);
    }

    var rtp_channel = BroadcastChannel.init(.{
        .deinit = deinitPacket,
        .deinit_ctx = &memory_pool,
        .empty = .{ .header = undefined, .payload = &.{} },
    });
    // No need for rtp_channel.deinit() since all the buffers will be released when the
    // memory is destroyed.

    publisher_handler.channel = &rtp_channel;

    try grp.concurrent(io, exit, .{ io, &publisher_handler.done });
    try publisher_handler.gathering_done.wait(io);

    try encodeSdp(pc);

    const Viewer = struct {
        pc: webrtc.PeerConnection,
        handler: ViewerHandler,
    };

    var viewers = std.ArrayList(Viewer).empty;
    defer {
        for (viewers.items) |*viewer| viewer.pc.deinit();
        viewers.deinit(allocator);
    }

    while (queue.getOne(io)) |offer| {
        defer offer.deinit();

        const viewer = try viewers.addOne(allocator);
        errdefer _ = viewers.swapRemove(viewers.items.len - 1);

        viewer.handler = ViewerHandler{ .io = io, .channel = &rtp_channel, .grp = &grp, .sender = undefined };
        viewer.pc = try .init(io, allocator, .{ .media_engine = &media_engine, .handler = viewer.handler.peerConnectionHandler() });

        viewer.handler.sender = try viewer.pc.addTrack(.init(io, .video), "stream");
        try viewer.pc.setRemoteDescription(offer.value);
        const answer = try viewer.pc.createAnswer();
        try viewer.pc.setLocalDescription(answer);

        try viewer.handler.gathering_done.wait(io);
        try encodeSdp(&viewer.pc);
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

fn receivePublishedData(userdata: ?*anyopaque, _: *webrtc.RtpReceiver, event: webrtc.RtpReceiver.TrackEvent) void {
    const c: *PublisherHandler = @ptrCast(@alignCast(userdata.?));
    const buffer = c.memory_pool.create(c.allocator) catch return;
    @memcpy(buffer[0..event.rtp.payload.len], event.rtp.payload);
    const packet = rtp.Packet{
        .header = event.rtp.header,
        .payload = buffer[0..event.rtp.payload.len],
    };
    c.channel.send(c.io, packet);
}

fn sendPli(io: Io, receiver: *webrtc.RtpReceiver) !void {
    while (true) {
        try io.sleep(.fromSeconds(3), .awake);
        receiver.sendPli() catch return;
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
