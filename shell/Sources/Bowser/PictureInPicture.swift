import AppKit
import WebKit

@MainActor
enum PictureInPicture {
    // Prefer an existing PiP session, then playing videos, then rendered area.
    // Same-origin frames and open shadow roots are traversed without changing
    // the site's origin boundaries or copying its media into a second player.
    static let toggleScript = #"""
    (() => {
      const videos = [];
      function collect(root) {
        videos.push(...root.querySelectorAll('video'));
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) collect(el.shadowRoot);
          if (el.tagName === 'IFRAME') {
            try { if (el.contentDocument) collect(el.contentDocument); } catch (_) {}
          }
        }
      }
      collect(document);
      const current = videos.find(v => v.webkitPresentationMode === 'picture-in-picture');
      if (current) { current.webkitSetPresentationMode('inline'); return 'exiting'; }
      const area = v => { const r = v.getBoundingClientRect(); return Math.max(0, r.width) * Math.max(0, r.height); };
      const eligible = videos.filter(v => v.readyState >= 1 && v.videoWidth > 0 &&
        typeof v.webkitSupportsPresentationMode === 'function' &&
        v.webkitSupportsPresentationMode('picture-in-picture'));
      eligible.sort((a,b) => Number(!b.paused && !b.ended) - Number(!a.paused && !a.ended) || area(b) - area(a));
      if (!eligible.length) return 'unavailable';
      eligible[0].webkitSetPresentationMode('picture-in-picture');
      return 'entering';
    })()
    """#

    static func toggle(_ engine: EngineView) {
        engine.webView.evaluateJavaScript(toggleScript) { [weak engine] result, error in
            guard let engine, let window = engine.window else { return }
            if error != nil || result as? String == "unavailable" {
                let alert = NativeUIHost.alert("pip-unavailable", [:])
                alert.beginSheetModal(for: window)
            }
        }
    }
}
