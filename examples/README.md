# Examples

A collection of examples demonstrating how to use the library.

The examples are a rewrite of the [pion](https://github.com/pion/webrtc) examples in Zig.

### Media API

* [Play from Disk](play-from-disk): Demonstrates how to send video to your browser from a file saved to disk.
* [Play from Disk Renegotiation](play-from-disk-renegotiation): an extension of the play-from-disk example, but demonstrates how you can add/remove video tracks from an already negotiated PeerConnection.
* [Reflect](reflect): Demonstrates how to send video from your browser to the server and back to your browser.

### Usage

All examples will start a web server at port `9000` that will serve the javascript/html files. Head to your browser and open `http://localhost:9000` to start playing the video.

For building the project, check each example's README.md for instructions. Most examples can be built and run with the following command:

```bash
zig build run -- <args>
```

Where `<args>` are the arguments for the example. For example, the play-from-disk example takes a single argument, which is the path to the ivf file to play.