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

  // ---- the tap (v1.4): tee the audio bytes the PLAYER ITSELF downloads.
  // Stream URLs are protocol-guarded (SABR: bare fetches 403, formats
  // appear and vanish) — but the player's own requests always work, so we
  // clone them. Chunks are keyed by their range= start for ordered
  // reassembly; arming reloads the video in place so the init segment is
  // captured too.
  var cap = { chunks: {}, bytes: 0, lastEmit: 0, lastGrowth: 0, ctype: null };

  function capRecord(url, ab) {
    try {
      var m = /[?&]range=(\d+)-/.exec(url);
      var start = m ? +m[1] : cap.bytes;
      if (cap.chunks[start] === undefined) {
        cap.chunks[start] = new Uint8Array(ab);
        cap.bytes += ab.byteLength;
        cap.lastGrowth = Date.now();
      }
    } catch (e) {}
  }

  function capAssembled() {
    var starts = Object.keys(cap.chunks).map(Number).sort(function (a, b) { return a - b; });
    var total = 0;
    starts.forEach(function (k) { total += cap.chunks[k].length; });
    var out = new Uint8Array(total);
    var off = 0;
    starts.forEach(function (k) { out.set(cap.chunks[k], off); off += cap.chunks[k].length; });
    return out;
  }

  function audioUrl(u) {
    return u && u.indexOf("videoplayback") !== -1 && /mime=audio/.test(u);
  }

  var origFetch = window.fetch;
  window.fetch = function (input) {
    var url = (typeof input === "string") ? input : (input && input.url);
    var promise = origFetch.apply(this, arguments);
    if (audioUrl(url)) {
      promise = promise.then(function (resp) {
        try {
          if (!cap.ctype) cap.ctype = resp.headers.get("content-type");
          resp.clone().arrayBuffer().then(function (ab) { capRecord(url, ab); }).catch(function () {});
        } catch (e) {}
        return resp;
      });
    }
    return promise;
  };

  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) { this.__dubUrl = u; return origOpen.apply(this, arguments); };
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    if (audioUrl(xhr.__dubUrl)) {
      xhr.addEventListener("load", function () {
        try { if (xhr.response instanceof ArrayBuffer) capRecord(xhr.__dubUrl, xhr.response); } catch (e) {}
      });
    }
    return origSend.apply(xhr, arguments);
  };

  // Ship the assembled audio to the brain: cumulative (init segment + all
  // fragments = a valid file), re-sent as it grows, when growth pauses.
  function capEmitter() {
    if (!state.on) return;
    var grown = cap.bytes > cap.lastEmit + 150000;
    var settled = Date.now() - cap.lastGrowth > 4000;
    if (grown && settled && cap.bytes > 300000) {
      cap.lastEmit = cap.bytes;
      var blob = new Blob([capAssembled()]);
      var PART = 2500000;
      var total = Math.ceil(blob.size / PART);
      plog("shipping captured audio: " + Math.round(blob.size / 1e5) / 10 + "MB (" + (cap.ctype || "?") + ")");
      (function sendPart(i) {
        if (i >= total) return;
        var reader = new FileReader();
        reader.onload = function () {
          window.bowser.emit({ kind: "dub_audio", part: i, total: total,
                               data: reader.result.split(",")[1] });
          sendPart(i + 1);
        };
        reader.readAsDataURL(blob.slice(i * PART, (i + 1) * PART));
      })(0);
    }
  }
  setInterval(capEmitter, 2000);

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
    // Restart the stream with the tap armed: reload the current video in
    // place at the current position, so the player refetches everything —
    // init segment included — through our tee.
    fetchAudio: function () {
      var player = document.querySelector("#movie_player");
      if (!player || !player.loadVideoById || !player.getVideoData) {
        plog("player api unavailable for restream");
        return "no player api";
      }
      var id = player.getVideoData().video_id;
      var v = video();
      var t = v ? Math.floor(v.currentTime) : 0;
      cap.chunks = {}; cap.bytes = 0; cap.lastEmit = 0; cap.lastGrowth = Date.now(); cap.ctype = null;
      player.loadVideoById(id, t);
      plog("restreaming " + id + " from " + t + "s through the tap");
      return "fetching";
    },
    status: function () {
      return JSON.stringify({ on: state.on,
                              cached: Object.keys(state.segments).length,
                              playing: state.playingT0 });
    }
  };
})();
