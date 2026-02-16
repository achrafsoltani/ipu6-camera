// Enable PipeWire camera support in Firefox WebRTC.
// Without this, Firefox only enumerates cameras via V4L2 — which fails inside
// the Snap sandbox because the portal-based PipeWire path is not used.
// See: https://bugzilla.mozilla.org/show_bug.cgi?id=1location
pref("media.webrtc.camera.allow-pipewire", true);
