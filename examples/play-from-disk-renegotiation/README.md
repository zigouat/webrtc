# Play from Disk Renegotiation

An extension of the play-from-disk example, but demonstrates how you can add/remove video tracks from an already negotiated PeerConnection.

## Instructions

The file should be an ivf with VP8 video stream. If you don't have one, you can use ffmpeg to convert it:

```bash
ffmpeg -i $INPUT_FILE -c:v libvpx -g 30 -b:v 2M output.ivf
```

You can build the zig project and run the program like this:
```bash
zig build run -- output.ivf
```

This also will start a web server at port `9000` that'll server the javascript/html files. Head to your browser and open `http://localhost:9000` to start playing the video.