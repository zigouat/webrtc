# WebRTC

Zig implementation of the WebRTC API.

## Status

The project is under active development. The API and even the whole architecture may change in the future. 
The current implementation is not yet production-ready.

## Architecture
The architecture follows the WebRTC specification (at least for the API surface). The callbacks are replaced by a more idiomatic Zig approach
which relies on `std.Io`. This decouples the library from the I/O implementation and allows for more flexibility in how the library is used (it can be used with thread pool or async I/O, for example).

## Features
The end goal is to implement the whole WebRTC API in pure Zig, the current implementation has the following features:

* SDP parsing and generation
* ICE (Interactive Connectivity Establishment) implementation only support local candidates for now. (no STUN/TURN support yet)
* DTLS using `mbedtls`.
* SRTP encryption and decryption with AES_CM_HMAC_SHA1_80 and AES_CM_HMAC_SHA1_32 profiles.
* Sending and receiving H264 and VP8 video streams.
* Sending and receiving Opus audio streams.
* Bundling of the above features into a `PeerConnection` API. (Note: only bundling is supported for now, no unbundling yet)
* RTCP sender report and PLI feedback support.

## Installation
Add `webrtc` as a dependency in your `build.zig.zon` file:

```bash
zig fetch --save git+https://github.com/zigouat/webrtc.git
```

Then, in your `build.zig` file, add the following:

```zig
const webrtc = b.dependecy("webrtc", .{ .target = .target, .optimize = optimize });

exe.root_module.addImportPath("webrtc", webrtc.module("webrtc"));
```

## Usage
```zig
const std = @import("std");
const webrtc = @import("webrtc");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var pc1 = try webrtc.PeerConnection.init(io, allocator, .{});
    defer pc1.deinit();

    var pc2 = try webrtc.PeerConnection.init(io, allocator, .{});
    defer pc2.deinit();

    _ = try pc1.addTrack(.initWithId("video-track", .video), "stream");

    const offer = try pc1.createOffer();
    try pc1.setLocalDescription(offer);

    var offer_with_candidates = (try pc1.getLocalDescription()).?;
    defer offer_with_candidates.deinit(allocator);
    try pc2.setRemoteDescription(offer_with_candidates);

    const answer = try pc2.createAnswer();
    try pc2.setLocalDescription(answer);
    try pc1.setRemoteDescription(answer);

    var grp: Io.Group = .init;
    try grp.concurrent(io, listenForEvents, .{ io, &pc1 });
    try grp.concurrent(io, listenForEvents, .{ io, &pc2 });
    try grp.await(io);
}

fn listenForEvents(io: std.Io, pc: *webrtc.PeerConnection) !void {
    _ = io;

    // Start listening for events from the PeerConnection...
    while (pc.poll()) |event| {
        _ = event;
    } else |_| {}
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