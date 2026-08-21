// Live voice dubbing, page half (bowser-browser-dku): when the dubber mod
// switches this tab on, capture the video's audio in STANDALONE 6s chunks
// (MediaRecorder is restarted per chunk — continuation chunks aren't
// independently decodable files) and emit them to the brain; play returned
// English TTS in order while the original is ducked. ~8s behind live by
// design — a consecutive interpreter, not simultaneous (that's v2).
(function () {
  if (window.top !== window) return;
  if (window.__bowserDub) return;

  var CHUNK_MS = 6000;
  var state = { on: false, recorder: null, seq: 0, nextPlay: 0, buffer: {}, playing: false, video: null };

  function video() { return document.querySelector("video"); }

  function startRecorder() {
    if (!state.on) return;
    var v = video();
    if (!v || v.paused) { setTimeout(startRecorder, 800); return; }
    var stream;
    try { stream = v.captureStream(); } catch (e) { return; }
    var audio = new MediaStream(stream.getAudioTracks());
    if (!audio.getAudioTracks().length) { setTimeout(startRecorder, 800); return; }
    var rec = new MediaRecorder(audio, { mimeType: "audio/webm;codecs=opus" });
    var mySeq = state.seq++;
    rec.ondataavailable = function (e) {
      if (!state.on || !e.data || e.data.size < 4000) return; // skip silence/stubs
      var reader = new FileReader();
      reader.onload = function () {
        var b64 = reader.result.split(",")[1];
        window.bowser.emit({ kind: "dub_chunk", seq: mySeq, data: b64 });
      };
      reader.readAsDataURL(e.data);
    };
    rec.onstop = function () { if (state.on) startRecorder(); };
    state.recorder = rec;
    rec.start();
    setTimeout(function () { if (rec.state !== "inactive") rec.stop(); }, CHUNK_MS);
  }

  function playNext() {
    if (state.playing) return;
    // Stay near-live: if we're far behind, skip ahead.
    var seqs = Object.keys(state.buffer).map(Number);
    if (seqs.length > 3) { state.nextPlay = Math.min.apply(null, seqs); }
    var b64 = state.buffer[state.nextPlay];
    if (b64 === undefined) return;
    delete state.buffer[state.nextPlay];
    state.nextPlay++;
    if (b64 === null) { playNext(); return; } // untranslatable chunk: skip
    state.playing = true;
    var a = new Audio("data:audio/mpeg;base64," + b64);
    a.onended = a.onerror = function () { state.playing = false; playNext(); };
    a.play().catch(function () { state.playing = false; });
  }

  window.__bowserDub = {
    start: function () {
      if (state.on) return "already on";
      state.on = true;
      state.seq = 0; state.nextPlay = 0; state.buffer = {}; state.playing = false;
      var v = video();
      if (v) { state.video = v; v.dataset.dubVolume = v.volume; v.volume = 0.15; }
      startRecorder();
      return "dubbing on";
    },
    stop: function () {
      state.on = false;
      if (state.recorder && state.recorder.state !== "inactive") state.recorder.stop();
      state.buffer = {};
      var v = state.video || video();
      if (v && v.dataset.dubVolume) { v.volume = +v.dataset.dubVolume; delete v.dataset.dubVolume; }
      return "dubbing off";
    },
    // Brain delivers each translated chunk here (b64 mp3, or null to skip).
    deliver: function (seq, b64) {
      state.buffer[seq] = b64;
      playNext();
      return "ok";
    },
    status: function () {
      return JSON.stringify({ on: state.on, seq: state.seq, next: state.nextPlay,
                              buffered: Object.keys(state.buffer).length });
    }
  };
})();
