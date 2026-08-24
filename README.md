# WebRTC

Zig implementation of the WebRTC API.

## Status

The project is under active development. The API and even the whole architecture may change in the future. 
The current implementation is not yet production-ready.

## Supported Zig/Platforms
Supported Zig version: `0.16.0`.

Tested platforms:
* Linux x86_64/aarch64
* macOS x86_64/aarch64
* Windows x86_64 (with zio)

## Architecture
The architecture follows the WebRTC specification (at least for the API surface). It uses `std.Io` for IO. This decouples the library from the I/O implementation and allows for more flexibility in how the library is used (it can be used with thread pool or async I/O, for example).

## Features
The end goal is to implement the whole WebRTC API in pure Zig, the current implementation has the following features:

* SDP parsing and generation
* ICE (Interactive Connectivity Establishment): Support IPv4/IPv6, STUN and TURN candidates. Only UDP is supported for now.
* DTLS using `mbedtls`.
* SRTP encryption and decryption with AES_CM_HMAC_SHA1_80 and AES_CM_HMAC_SHA1_32 profiles.
* Sending and receiving H264 and VP8 video streams.
* Sending and receiving Opus audio streams.
* Bundling of the above features into a `PeerConnection` API. (Note: only bundling is supported for now, no unbundling yet)
* RTCP sender report, PLI feedback and NACK/RTX support.

## Installation
Add `webrtc` as a dependency in your `build.zig.zon` file:

```bash
zig fetch --save git+https://github.com/zigouat/webrtc.git#v0.1.0
```

Then, in your `build.zig` file, add the following:

```zig
const webrtc = b.dependency("webrtc", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("webrtc", webrtc.module("webrtc"));
```

## Usage
The following example of how to send data from `pc1` to `pc2`:

```zig
const std = @import("std");
const webrtc = @import("webrtc");
const rtp = @import("rtp");

const Io = std.Io;

const Handler = struct {
    io: Io,
    gathering_done: Io.Event,
    connected: Io.Event,

    fn init(io: Io) Handler {
        return Handler{
            .io = io,
            .gathering_done = .unset,
            .connected = .unset,
        };
    }

    fn peerConnectionHandler(handler: *Handler) webrtc.PeerConnectionHandler {
        return .{
            .userdata = handler,
            .vtable = &.{
                .onSignalingStateChange = onSignalingStateChange,
                .onConnectionStateChange = onConnectionStateChange,
                .onGatheringStateChange = onGatheringStateChange,
                .onTrack = onTrack,
            },
        };
    }

    fn onSignalingStateChange(_: ?*anyopaque, state: webrtc.PeerConnection.SignalingState) void {
        std.debug.print("[Handler] Signaling state changed: {}\n", .{state});
    }

    fn onConnectionStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.ConnectionState) void {
        std.debug.print("[Handler] Connection state changed: {}\n", .{state});
        const h: *Handler = @ptrCast(@alignCast(userdata.?));
        if (state == .connected) {
            h.connected.set(h.io);
        }
    }

    fn onGatheringStateChange(userdata: ?*anyopaque, state: webrtc.PeerConnection.GatheringState) void {
        std.debug.print("[Handler] Gathering state changed: {}\n", .{state});
        const handler: *Handler = @ptrCast(@alignCast(userdata.?));
        if (state == .complete) {
            handler.gathering_done.set(handler.io);
        }
    }

    fn onTrack(_: ?*anyopaque, event: webrtc.RtpTransceiver.TrackEventInit) void {
        const track = event.track;
        std.debug.print("[Handler] Track event of type {s}: {s}\n", .{ @tagName(track.kind), track.id });
        event.receiver.registerCallback(null, receiveData);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var handler1 = Handler.init(io);
    var handler2 = Handler.init(io);

    var media_engine: webrtc.MediaEngine = .init(.{ .enable_rtx = true });
    defer media_engine.deinit(allocator);
    try media_engine.registerDefaultCodecs(allocator);

    var pc1 = try webrtc.PeerConnection.init(io, allocator, .{
        .media_engine = &media_engine,
        .handler = handler1.peerConnectionHandler(),
    });
    defer pc1.deinit();

    var pc2 = try webrtc.PeerConnection.init(io, allocator, .{
        .media_engine = &media_engine,
        .handler = handler2.peerConnectionHandler(),
    });
    defer pc2.deinit();

    const sender = try pc1.addTrack(.initWithId("video-track", .video), "stream");

    var grp: Io.Group = .init;

    const offer = try pc1.createOffer();
    try pc1.setLocalDescription(offer);

    try handler1.gathering_done.wait(io);
    var offer_with_candidates = (try pc1.getLocalDescription()).?;
    defer offer_with_candidates.deinit(allocator);

    try pc2.setRemoteDescription(offer_with_candidates);
    const answer = try pc2.createAnswer();
    try pc2.setLocalDescription(answer);
    try pc1.setRemoteDescription(answer);

    try handler1.connected.wait(io);
    try grp.concurrent(io, sendData, .{ io, sender });

    try grp.await(io);
}

fn sendData(io: Io, sender: *webrtc.RtpSender) !void {
    var packet = rtp.Packet{
        .header = .{
            .version = 2,
            .padding = false,
            .extension = false,
            .csrc_count = 0,
            .marker = false,
            .payload_type = 96,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 12345,
        },
        .payload = "Hello, WebRTC!",
    };

    while (true) {
        try io.sleep(.fromMilliseconds(10), .awake);
        sender.sendRtp(&packet) catch unreachable;

        packet.header.sequence_number +%= 1;
        packet.header.timestamp +%= 3000;
    }
}

fn receiveData(_: ?*anyopaque, _: *webrtc.RtpReceiver, event: webrtc.RtpReceiver.TrackEvent) void {
    std.debug.print("Seq: {}\n", .{event.rtp.header.sequence_number});
}
```

For more complete examples, check [examples](./examples) folder.

### Note For Windows Users
Currently the examples are not working on Windows because `std.Io.net.Socket.receiveTimeout` is not implemented. You can still run 
the examples by depending on third party package like [zio](https://github.com/lalinsky/zio).

## Other related projects

The following projects are related to WebRTC and some of them used as a dependency in this project:
* [media](https://github.com/zigouat/media) - A zig library for media common structures and codecs.
* [media-protocols](https://github.com/zigouat/media-protocols) - A zig library for media protocols (RTP, RTCP, SDP, etc.).
* [media-formats](https://github.com/zigouat/media-formats) - A zig library for muxers/demuxers (MP4, IVF, etc.).