# Reflect

reflect demonstrates how with one PeerConnection you can send video from browser and have the packets sent back. This example could be easily extended to do server side processing.

## Instructions

### Open reflect example page
[jsfiddle.net](https://jsfiddle.net/g643ft1k/) you should see two text-areas and a 'Start Session' button.

### Run reflect, with your browsers SessionDescription as stdin
In the jsfiddle the top textarea is your browser's Session Description. Press `Copy browser SDP to clipboard` or copy the base64 string manually.
We will use this value in the next step.

#### Linux/macOS
Run `echo $BROWSER_SDP | zig build run-reflect`
#### Windows
1. Paste the SessionDescription into a file.
1. Run `zig build run-reflect < my_file`

### Input reflect's SessionDescription into your browser
Copy the text that `reflect` just emitted and copy into second text area

### Hit 'Start Session' in jsfiddle, enjoy your video!
Your browser should send video, and then it will be relayed right back to you.
