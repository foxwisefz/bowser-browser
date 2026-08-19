// music.youtube.com cold-start resume (bowser-browser-hj1).
//
// The engine-level media hook seeks + plays once a stream EXISTS, but after
// an engine death YT Music never rebuilds its player by itself — a real
// click on the play control is what makes the app restore its queue and
// attach the MediaSource. Only fires when the hook's snapshot says media was
// PLAYING within the last two minutes (mirrors the shell's 120s window), so
// an ordinary visit never gets a surprise click.
//
// In a background tab the click alone stalls (WebKit defers media work for
// unmounted webviews) — the media_warm mod mounts the tab invisibly for a
// few seconds so the pipeline can start; this script just keeps clicking
// until the stream is up, then gets out of the way.
(function () {
  var KEY = "bowser-media:" + location.host + location.pathname;
  var d = null;
  try { d = JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) {}
  if (!d || d.paused || Date.now() - d.at > 120000) return;
  var tries = 0;
  var iv = setInterval(function () {
    var m = document.querySelector("video, audio");
    if (m && m.duration) { clearInterval(iv); return; } // stream is up — the media hook takes over
    if (++tries > 120) { clearInterval(iv); return; }   // give up after ~60s
    // NEVER click while a play is in flight (m exists, paused=false, no
    // duration yet — the stream is attaching): the play/pause control
    // TOGGLES, and a second click flips the resume back off. That race
    // parity decided whether music came back (bowser-browser-8i6).
    if (m && !m.paused) return;
    var b = document.querySelector("#play-pause-button");
    if (b) b.click();
  }, 500);
})();
