// Live voice dubbing, page half v1.2 (bowser-browser-dku): NO capture — the
// brain fetches the video's audio itself (yt-dlp) and streams back
// time-stamped English segments; this half is a synchronized player. Each
// segment covers [t0, t0+20s); every 300ms we check video.currentTime and
// hard-switch to the segment that owns it, seeking within the segment —
// pause, scrub, and replay all stay in sync. Both in-page capture paths are
// dead on WebKit: captureStream does not exist and MediaElementSource
// outputs silence on YouTube's MSE stream (measured amplitude: zero).
(function () {
  if (window.top !== window) return;
  if (window.__bowserDub) return;

  var SEG = 20; // seconds per segment, must match the brain's ffmpeg cut
  var state = { on: false, segments: {}, timer: null, audio: null, playingT0: null, video: null };

  function plog(msg) {
    try { window.bowser.emit({ kind: "dub_log", msg: String(msg).slice(0, 120) }); } catch (e) {}
  }

  function video() { return document.querySelector("video"); }

  function tick() {
    if (!state.on) return;
    var v = video();
    if (!v) return;
    if (v.paused) {
      if (state.audio && !state.audio.paused) state.audio.pause();
      return;
    }
    var t = v.currentTime;
    var t0 = Math.floor(t / SEG) * SEG;
    var b64 = state.segments[t0];
    if (state.playingT0 === t0) {
      // Same segment: resume if we paused with the video, nudge if drifted.
      if (state.audio) {
        if (state.audio.paused) state.audio.play().catch(function () {});
        var want = t - t0;
        if (Math.abs(state.audio.currentTime - want) > 2.5) state.audio.currentTime = want;
      }
      return;
    }
    if (b64 === undefined) return; // not translated yet — stay quiet
    if (state.audio) { state.audio.pause(); state.audio = null; }
    state.playingT0 = t0;
    if (b64 === null) return;      // segment had no speech
    var a = new Audio("data:audio/mpeg;base64," + b64);
    state.audio = a;
    a.oncanplay = function () {
      var offset = video() ? Math.max(0, video().currentTime - t0) : 0;
      if (offset > 0.5) a.currentTime = offset;
      a.play().catch(function (e) { plog("segment play blocked: " + e.name); });
    };
  }

  window.__bowserDub = {
    start: function () {
      if (state.on) return "already on";
      state.on = true;
      state.playingT0 = null;
      var v = video();
      if (v) { state.video = v; v.dataset.dubVolume = v.volume; v.volume = 0.2; }
      state.timer = setInterval(tick, 300);
      plog("player armed (" + Object.keys(state.segments).length + " segments cached)");
      return "dubbing on";
    },
    stop: function () {
      state.on = false;
      if (state.timer) clearInterval(state.timer);
      if (state.audio) { state.audio.pause(); state.audio = null; }
      state.playingT0 = null;
      var v = state.video || video();
      if (v && v.dataset.dubVolume) { v.volume = +v.dataset.dubVolume; delete v.dataset.dubVolume; }
      return "dubbing off";
    },
    // Brain delivers each translated segment: start second + b64 mp3 (null = no speech).
    deliver: function (t0, b64) {
      state.segments[t0] = b64;
      return "ok";
    },
    reset: function () { state.segments = {}; state.playingT0 = null; return "reset"; },
    status: function () {
      return JSON.stringify({ on: state.on,
                              cached: Object.keys(state.segments).length,
                              playing: state.playingT0 });
    }
  };
})();
