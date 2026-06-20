const std = @import("std");
const media = @import("media");
const mp4 = @import("formats").mp4;
const rtp = @import("rtp");
const webrtc = @import("webrtc");

const Io = std.Io;

const html_file = @embedFile("index.html");
const js_file = @embedFile("pc.js");

var pc: webrtc.PeerConnection = undefined;
var grp: Io.Group = .init;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = Io.Threaded.init(allocator, .{
        .async_limit = .unlimited,
        .concurrent_limit = .unlimited,
    });
    defer threaded.deinit();

    const io = threaded.io();

    var arg_iterator = init.minimal.args.iterate();
    _ = arg_iterator.next();
    const file_path = arg_iterator.next().?;

    var file_reader = try mp4.Reader.init(io, allocator, null, file_path);
    defer file_reader.deinit(allocator);

    var it = file_reader.streamIterator();
    while (it.next()) |stream| {
        if (stream.codec == .h264) break;
    } else return error.NoH264StreamFound;

    pc = try .init(io, allocator, .{});
    defer pc.deinit();

    try pc.addTrack(.{ .id = "video-track", .kind = .video });

    try grp.concurrent(io, startHttpServer, .{ io, allocator });

    while (pc.poll()) |event| switch (event) {
        .connection_state => |state| switch (state) {
            .connected => {
                std.log.info("Peer connected", .{});
                try grp.concurrent(io, sendMediaData, .{ io, allocator, &file_reader });
            },
            .disconnected => {
                std.log.warn("Peer disconnected, exiting...", .{});
                return;
            },
            else => {},
        },
        else => {},
    } else |_| return;
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
    } else if (std.mem.eql(u8, "/pc.js", req.head.target)) {
        try req.respond(js_file, .{
            .transfer_encoding = .none,
            .extra_headers = &[_]std.http.Header{.{ .name = "Content-Type", .value = "application/javascript" }},
        });
    } else if (std.mem.eql(u8, req.head.target, "/offer") and req.head.method == .GET) {
        std.log.info("Create offer", .{});
        const offer = try pc.createOffer();
        try pc.setLocalDescription(offer);

        var body_writer = try req.respondStreaming(&.{}, .{ .respond_options = .{ .transfer_encoding = .none } });

        try pc.writeLocalDescription(&body_writer.writer);
        try body_writer.flush();
    } else if (std.mem.eql(u8, req.head.target, "/answer") and req.head.method == .POST) {
        std.log.info("Set remote description", .{});
        const answer = allocator.alloc(u8, req.head.content_length.?) catch return;
        defer allocator.free(answer);

        var reader = req.readerExpectNone(&.{});
        try reader.readSliceAll(answer);
        try req.respond(&.{}, .{ .transfer_encoding = .none });

        try pc.setRemoteDescription(.{ .desc_type = .answer, .sdp = answer });
    }
}

fn sendMediaData(io: Io, allocator: std.mem.Allocator, reader: *mp4.Reader) !void {
    doSendMediaData(io, allocator, reader) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| std.log.err("Error occurred while sending file: {}", .{e}),
    };
}

fn doSendMediaData(io: Io, allocator: std.mem.Allocator, reader: *mp4.Reader) !void {
    const video_stream = blk: {
        var it = reader.streamIterator();
        while (it.next()) |stream| if (stream.codec == .h264) break :blk stream;
        unreachable;
    };

    var read_buffer: [4096]u8 = @splat(0);
    var frame_iterator = try reader.frameIterator(allocator, &read_buffer);
    defer frame_iterator.deinit(allocator);

    var h264_pack = rtp.packetizer.H264.init(io, .{ .payload_type = 0 });
    var rtp_buffer: [1300]u8 = @splat(0);

    const sps, const pps = try getParameterSets(&video_stream);
    const tr = &pc.transceivers.items[0];
    const start_timestamp = Io.Clock.now(.awake, io).toMilliseconds();
    var curr_packet = try frame_iterator.next(allocator);

    outer: while (true) {
        const elapsed: u64 = @intCast(std.Io.Clock.now(.awake, io).toMilliseconds() - start_timestamp);

        while (true) {
            if (curr_packet == null) break :outer;
            const dts = elapsed * video_stream.time_base.den / std.time.ms_per_s;
            if (curr_packet.?.dts >= dts) break;

            var p = curr_packet.?;
            defer p.deinit(allocator);

            // ignore other streams
            if (p.stream_id != video_stream.id) {
                curr_packet = try frame_iterator.next(allocator);
                continue;
            }

            if (p.flags.keyframe and sps.len != 0) {
                p = try prependParameterSets(allocator, &p, sps, pps);
                curr_packet.?.deinit(allocator);
            }

            p.dts = @intCast(@divTrunc(@as(i128, p.dts) * video_stream.time_base.num * 90_000, @as(i128, video_stream.time_base.den)));

            var it = h264_pack.packetize(&p);
            while (try it.next(&rtp_buffer)) |rtp_packet| try tr.sendRtp(&rtp_packet);

            curr_packet = try frame_iterator.next(allocator);
        }

        try io.sleep(.fromMilliseconds(10), .awake);
    }

    // TODO: close peer connection
}

fn getParameterSets(stream: *const media.Stream) !struct { []const u8, []const u8 } {
    var sps: []const u8 = &.{};
    var pps: []const u8 = &.{};

    const dcr = try media.h264.DecoderConfigurationRecord.parse(stream.extra_data);
    var it = dcr.iterateParameterSets();
    while (try it.next()) |ps| {
        const head = media.h264.NalHeader.fromByte(ps[0]);
        switch (head.nal_type) {
            .sps => sps = ps,
            .pps => pps = ps,
            else => {},
        }
    }

    return .{ sps, pps };
}

fn prependParameterSets(
    allocator: std.mem.Allocator,
    packet: *const media.Packet,
    sps: []const u8,
    pps: []const u8,
) !media.Packet {
    var result = packet.*;
    const len = packet.data.len + sps.len + pps.len + 8;
    result = try media.Packet.alloc(allocator, len);
    result.flags = packet.flags;
    result.dts = packet.dts;
    result.pts = packet.pts;
    result.stream_id = packet.stream_id;

    var writer = Io.Writer.fixed(result.mutableData().?);
    try writer.writeInt(u32, @intCast(sps.len), .big);
    try writer.writeAll(sps);
    try writer.writeInt(u32, @intCast(pps.len), .big);
    try writer.writeAll(pps);
    try writer.writeAll(packet.data);

    return result;
}
