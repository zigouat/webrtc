# play-from-disk

Play from disk shows how to send an mp4 file from your desktop/server to your browser.

## Instructions

The file should be an mp4 with H264 video stream (the only support codec for now) with baseline profile. If you don't have one, you can use ffmpeg to convert it:

```bash
ffmpeg -i input.mp4 -c:v h264 -profile:v baseline output.mp4
```

You can build the zig project and run the program like this:
```bash
zig build run -- output.mp4
```

This also will start a web server at port `9000` that'll server the javascript/html files. Head to your browser and open `http://localhost:9000` to start playing the video.