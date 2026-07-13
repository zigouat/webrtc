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

## Other related projects

The following projects are related to WebRTC and some of them used as a dependency in this project:
* [media](https://github.com/zigouat/media) - A zig library for media common structures and codecs.
* [media-protocols](https://github.com/zigouat/media-protocols) - A zig library for media protocols (RTP, RTCP, SDP, etc.).
* [media-formats](https://github.com/zigouat/media-formats) - A zig library for muxers/demuxers (MP4, IVF, etc.).