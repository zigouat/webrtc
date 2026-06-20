const SERVER = "";

const logEl = document.getElementById("log");
const videoEl = document.getElementById("video");

function log(msg) {
  console.log(msg);
  if (logEl) logEl.textContent += msg + "\n";
}

async function start() {
  // 1. Create the peer connection.
  const pc = new RTCPeerConnection({
    bundlePolicy: "max-bundle",
    iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
  });

  // Render the incoming media stream from the server in the video element.
  pc.ontrack = (event) => {
    log("Received remote track: " + event.track.kind);
    videoEl.srcObject = event.streams[0] || new MediaStream([event.track]);
  };

  pc.oniceconnectionstatechange = () => log("ICE state: " + pc.iceConnectionState);
  pc.onconnectionstatechange = () => log("Connection state: " + pc.connectionState);

  // We only receive video from the server.
  pc.addTransceiver("video", { direction: "recvonly" });

  // 2. Fetch the remote offer (raw SDP) from the server and apply it.
  log("Fetching offer from " + SERVER + "/offer ...");
  const offerSdp = await (await fetch(SERVER + "/offer")).text();
  await pc.setRemoteDescription({ type: "offer", sdp: offerSdp });
  log("Remote offer set.");

  // 3. Create an answer, set it locally, and wait for ICE gathering.
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  await waitForIceGathering(pc);

  // 4. Send the final answer SDP back to the server.
  log("Posting answer to " + SERVER + "/answer ...");
  await fetch(SERVER + "/answer", {
    method: "POST",
    headers: { "Content-Type": "application/sdp" },
    body: pc.localDescription.sdp,
  });

  log("Answer sent. Negotiation complete.");
}

// Resolve once ICE candidates are fully gathered so the SDP is complete
// (non-trickle), since the server expects a single answer.
function waitForIceGathering(pc) {
  if (pc.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((resolve) => {
    function check() {
      if (pc.iceGatheringState === "complete") {
        pc.removeEventListener("icegatheringstatechange", check);
        resolve();
      }
    }
    pc.addEventListener("icegatheringstatechange", check);
  });
}

document.getElementById("startBtn").addEventListener("click", () => {
  start().catch((err) => log("Error: " + err.message));
});
