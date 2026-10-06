# WebRTC

A sans-io zig implementation of the WebRTC API.

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
The implementation is a sans-io, the library will not do any I/O, it will only provide the WebRTC API and the user will have to implement the I/O themselves (e.g. sockets, timers, ...etc.).

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
* Data channels (support for reliable (un)ordered delivery).

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
Check the [examples](./examples) folder.

### Note For Windows Users
Currently the examples are not working on Windows because `std.Io.net.Socket.receiveTimeout` is not implemented. You can still run 
the examples by depending on third party package like [zio](https://github.com/lalinsky/zio).

## Other related projects

The following projects are related to WebRTC and some of them used as a dependency in this project:
* [media](https://github.com/zigouat/media) - A zig library for media common structures and codecs.
* [media-protocols](https://github.com/zigouat/media-protocols) - A zig library for media protocols (RTP, RTCP, SDP, etc.).
* [media-formats](https://github.com/zigouat/media-formats) - A zig library for muxers/demuxers (MP4, IVF, etc.).