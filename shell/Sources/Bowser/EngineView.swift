import AppKit
import WebKit

/// Relays page messages (console.* taps and window.bowser.emit) to the brain.
/// Separate object so the user content controller never retains EngineView.
private final class PageRelay: NSObject, WKScriptMessageHandler {
    weak var view: EngineView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let name = message.name
        let body = message.body
        MainActor.assumeIsolated {
            guard let id = view?.webviewId else { return }
            switch name {
            case "bowserConsole":
                guard let dict = body as? [String: Any] else { return }
                BrainBridge.shared.send([
                    "op": "event", "event": "console", "webview": id,
                    "level": dict["level"] as? String ?? "log",
                    "message": dict["message"] as? String ?? "",
                ])
            case "bowserEmit":
                // The page->brain duplex channel: whatever the page emits,
                // mods receive as {"event": "page", "payload": ...}.
                BrainBridge.shared.send([
                    "op": "event", "event": "page", "webview": id,
                    "payload": BrainBridge.jsonify(body),
                ])
            default:
                break
            }
        }
    }
}

/// The engine surface (ADR 0008): a WKWebView per tab. WebKit owns input,
/// rendering, and process isolation; this class owns identity, user content,
/// and event flow to the brain.
@MainActor
final class EngineView: NSView, WKNavigationDelegate, WKUIDelegate {
    private(set) static var live: [UInt64: EngineView] = [:]
    private static var nextId: UInt64 = 1

    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((String) -> Void)?
    var onThemeColor: ((NSColor?) -> Void)?

    private(set) var webviewId: UInt64 = 0
    private(set) var faviconPath: String?
    /// Last sampled page tint. Cached because a tab can be mounted long
    /// after it loaded, and the chrome has to catch up on the spot.
    private(set) var themeColor: NSColor?
    let webView: WKWebView

    private let pageRelay = PageRelay()
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var currentScripts: [String] = []
    private var currentStyles: [String] = []

    // The brain's last-pushed user content. set_user_content only reaches
    // webviews alive at push time — a tab opened later was born UNMODDED
    // (no site payloads, no mod scripts) until the next push
    // (bowser-browser-1af). New views seed from here instead.
    private(set) static var sharedScripts: [String] = []
    private(set) static var sharedStyles: [String] = []

    /// Same nil/[] semantics as applyUserContent: nil leaves that kind
    /// untouched, [] clears it.
    static func rememberUserContent(scripts: [String]?, styles: [String]?) {
        if let scripts { sharedScripts = scripts }
        if let styles { sharedStyles = styles }
    }

    private static let consoleHook = """
    (function () {
      ["log", "warn", "error", "info"].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try {
            window.webkit.messageHandlers.bowserConsole.postMessage({
              level: level,
              message: Array.prototype.map.call(arguments, String).join(" ")
            });
          } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      window.bowser = {
        emit: function (payload) {
          try { window.webkit.messageHandlers.bowserEmit.postMessage(payload); }
          catch (e) {}
        }
      };
    })();
    """

    /// The page starts this far below the window top — the chrome band's
    /// breathing room.
    /// Height of the chrome band. The page runs FULL height underneath it —
    /// the band is a click-through scrim, so page pixels show (and scroll)
    /// through the chrome.
    static let pageTopInset: CGFloat = 34

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, configuration: nil)
    }

    /// Popups (target=_blank) must be created with the configuration WebKit
    /// hands us in createWebViewWith — hence the injectable configuration.
    init(frame frameRect: NSRect, configuration external: WKWebViewConfiguration?) {
        let configuration = external ?? {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .default() // cookies/storage persist
            return c
        }()
        // Media resume after a respawn needs programmatic play().
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        webviewId = Self.nextId
        Self.nextId += 1
        Self.live[webviewId] = self

        pageRelay.view = self
        configuration.userContentController.add(pageRelay, name: "bowserConsole")
        configuration.userContentController.add(pageRelay, name: "bowserEmit")
        currentScripts = Self.sharedScripts
        currentStyles = Self.sharedStyles
        rebuildUserScripts()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Full Safari impersonation: WKWebView's default UA lacks the
        // "Version/x Safari/x" suffix and sites like YouTube Music sniff it.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        webView.frame = bounds
        addSubview(webView)

        urlObservation = webView.observe(\.url) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, let url = view.url?.absoluteString else { return }
                self.onURLChange?(url)
                BrainBridge.shared.send([
                    "op": "event", "event": "url_changed",
                    "webview": self.webviewId, "url": url,
                ])
            }
        }
        titleObservation = webView.observe(\.title) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let title = view.title ?? ""
                self.onTitleChange?(title)
                BrainBridge.shared.send([
                    "op": "event", "event": "title_changed",
                    "webview": self.webviewId, "title": title,
                ])
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var currentURLString: String? { webView.url?.absoluteString }

    // MARK: Commands

    func load(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }

    /// One zoom step (View menu / ⌘+ ⌘− ⌘0): 0.1 per step, clamped to
    /// 0.5–3.0; direction 0 resets to Actual Size.
    static func steppedZoom(_ current: Double, direction: Int) -> Double {
        guard direction != 0 else { return 1.0 }
        let next = ((current + Double(direction) * 0.1) * 10).rounded() / 10
        return min(max(next, 0.5), 3.0)
    }

    func zoom(direction: Int) {
        webView.pageZoom = Self.steppedZoom(Double(webView.pageZoom), direction: direction)
    }

    /// nil = leave that kind untouched; [] = clear. Applies on reload.
    func applyUserContent(scripts: [String]?, styles: [String]?, reload: Bool) {
        if let scripts { currentScripts = scripts }
        if let styles { currentStyles = styles }
        rebuildUserScripts()
        if reload { webView.reload() }
    }

    // The chrome band is transparent and the page runs under it; a root
    // transform shifts ALL content (fixed/sticky included — transforms
    // re-anchor them to the page) below the band. Shell-owned because the
    // band height is a shell concept.
    private static let bandOffsetHook = """
    (function () {
      if (window.top !== window) return;
      function apply() {
        if (document.getElementById("bowser-band-offset")) return;
        var s = document.createElement("style");
        s.id = "bowser-band-offset";
        // margin, NOT transform: a transform re-anchors position:fixed
        // elements (players, chat bubbles) to the page and strands them.
        // With margin, flow content starts below the band, fixed UI keeps
        // its viewport anchors, and sticky headers slide under the band on
        // scroll — the intended look.
        s.textContent = "body { margin-top: \(Int(EngineView.pageTopInset))px !important; }";
        (document.head || document.documentElement).appendChild(s);
      }
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply);
      apply();
    })();
    """

    // Media position survives engine death: snapshot currentTime/paused into
    // localStorage (WebKit persists it); on load, if the snapshot is FRESH
    // (a restart, not a revisit), seek and resume. Feels like a hiccup, not
    // a loss.
    static let mediaResumeWindowSeconds = 120
    static let mediaHook = """
    (function () {
      if (window.top !== window) return;
      var KEY = "bowser-media:" + location.host + location.pathname;
      var restored = false;
      function media() { return document.querySelector("video, audio"); }
      setInterval(function () {
        var m = media();
        if (!m || !m.duration) return;
        if (!restored) {
          restored = true;
          try {
            var d = JSON.parse(localStorage.getItem(KEY) || "null");
            if (d && Date.now() - d.at < \(mediaResumeWindowSeconds) * 1000) {
              m.currentTime = d.t;
              if (!d.paused) m.play().catch(function () {});
            }
          } catch (e) {}
        }
        // Gated on restored: during player cold-start the element reads
        // paused=false at t=0, and writing then would clobber the very
        // resume point the restore branch is about to use.
        if (restored && (!m.paused || m.currentTime > 0)) {
          try {
            localStorage.setItem(KEY, JSON.stringify(
              { t: m.currentTime, paused: m.paused, at: Date.now() }));
          } catch (e) {}
        }
      }, 500);
    })();
    """

    private func rebuildUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: Self.consoleHook,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.bandOffsetHook,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.mediaHook,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        for css in currentStyles {
            guard let encoded = try? JSONSerialization.data(withJSONObject: [css]),
                  let literal = String(data: encoded, encoding: .utf8)
            else { continue }
            let injector = """
            (function () {
              var s = document.createElement("style");
              s.textContent = \(literal)[0];
              (document.head || document.documentElement).appendChild(s);
            })();
            """
            controller.addUserScript(WKUserScript(
                source: injector, injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
        }
        for script in currentScripts {
            controller.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
        }
    }

    func tearDown() {
        EngineView.live.removeValue(forKey: webviewId)
        BrainBridge.shared.send([
            "op": "event", "event": "webview_closed", "webview": webviewId,
        ])
        urlObservation = nil
        titleObservation = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bowserConsole")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bowserEmit")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 0,
        ])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 2,
        ])
        sampleThemeColor()
        captureFavicon()
    }

    // A load that dies before commit used to vanish: the KVO url had already
    // told the brain the new URL, the webview stayed on about:blank, and the
    // session re-persisted a tab that never existed (bowser-browser-p7l).
    // Failures now emit load_status 3 and paint an inline error page whose
    // baseURL is the failed URL — the tab shows what went wrong, and the
    // brain's mirror stays consistent with what's on screen.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadFailure(error, provisional: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error, provisional: false)
    }

    private func handleLoadFailure(_ error: Error, provisional: Bool) {
        let nsError = error as NSError
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? webView.url?.absoluteString ?? ""
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 3,
            "url": failedURL, "error": nsError.localizedDescription,
        ])
        // A committed page that errors keeps its pixels; only a provisional
        // failure leaves the tab blank and needs the error page.
        guard provisional,
              Self.shouldShowErrorPage(domain: nsError.domain, code: nsError.code)
        else { return }
        webView.loadHTMLString(
            Self.errorPageHTML(url: failedURL, message: nsError.localizedDescription),
            baseURL: URL(string: failedURL)
        )
    }

    /// Cancellation (-999) means a newer load won the race; WebKit 102 means
    /// the navigation became a download or app handoff. Everything else left
    /// the user staring at a blank tab.
    static func shouldShowErrorPage(domain: String, code: Int) -> Bool {
        if domain == NSURLErrorDomain && code == NSURLErrorCancelled { return false }
        if domain == "WebKitErrorDomain" && code == 102 { return false }
        return true
    }

    static func errorPageHTML(url: String, message: String) -> String {
        let safeURL = htmlEscape(url)
        let safeMessage = htmlEscape(message)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, sans-serif; display: flex;
                 min-height: 90vh; align-items: center; justify-content: center; }
          main { max-width: 34em; text-align: center; }
          h1 { font-size: 1.2em; }
          .url { word-break: break-all; opacity: 0.7; }
        </style></head><body><main>
          <h1>This page didn&rsquo;t load</h1>
          <p class="url">\(safeURL)</p>
          <p>\(safeMessage)</p>
          <p><a href="\(safeURL)">Try again</a></p>
        </main></body></html>
        """
    }

    static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Favicon pipeline — probe, cache to ~/.bowser/favicons/<host>,
    // emit favicon_changed. Any tab UI (dock strips, tab trees) reads the
    // cached file path from events or hello.

    private static var fetchedHosts: Set<String> = []

    private static func faviconFile(for host: String) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bowser/favicons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = host.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).img")
    }

    private func captureFavicon() {
        guard let host = webView.url?.host else { return }
        let file = Self.faviconFile(for: host)

        if FileManager.default.fileExists(atPath: file.path) {
            announceFavicon(file.path)
            if Self.fetchedHosts.contains(host) { return }
        }
        guard !Self.fetchedHosts.contains(host) else { return }
        Self.fetchedHosts.insert(host)

        let probe = """
        (function () {
          var l = document.querySelector('link[rel~="icon"]');
          return l ? l.href : (location.origin + "/favicon.ico");
        })()
        """
        let id = webviewId
        webView.evaluateJavaScript(probe) { value, _ in
            guard let urlString = value as? String, let url = URL(string: urlString) else { return }
            // Capture only Sendables (id, file); the view is looked up by id
            // back on the main actor.
            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard let data, data.count > 16,
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 300
                else { return }
                try? data.write(to: file)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        EngineView.live[id]?.announceFavicon(file.path)
                    }
                }
            }.resume()
        }
    }

    private func announceFavicon(_ path: String) {
        faviconPath = path
        BrainBridge.shared.send([
            "op": "event", "event": "favicon_changed",
            "webview": webviewId, "path": path,
        ])
    }

    // Safari-style chrome tinting: prefer the page's theme-color meta,
    // fall back to its background; normalize via a computed style so any
    // CSS color form comes back as rgb()/rgba().
    private static let themeProbe = """
    (function () {
      // The chrome band sits directly above the page top — match what's
      // actually rendered there: the topmost element's effective background.
      var c = "";
      var el = document.elementFromPoint(window.innerWidth / 2, 2);
      while (el && el !== document.documentElement) {
        var bg = getComputedStyle(el).backgroundColor;
        if (bg && bg !== "rgba(0, 0, 0, 0)" && !/rgba\\(.*, 0\\)$/.test(bg)) { c = bg; break; }
        el = el.parentElement;
      }
      if (!c) {
        var m = document.querySelector('meta[name="theme-color"]');
        c = (m && m.content) || "";
      }
      if (!c) {
        c = getComputedStyle(document.body).backgroundColor;
        if (!c || c === "rgba(0, 0, 0, 0)")
          c = getComputedStyle(document.documentElement).backgroundColor;
      }
      var d = document.createElement("div");
      d.style.color = c;
      document.body.appendChild(d);
      var out = getComputedStyle(d).color;
      d.remove();
      return out;
    })()
    """

    private func sampleThemeColor() {
        webView.evaluateJavaScript(Self.themeProbe) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.themeColor = Self.parseCSSColor(value as? String)
                self.onThemeColor?(self.themeColor)
            }
        }
    }

    static func parseCSSColor(_ css: String?) -> NSColor? {
        guard let css else { return nil }
        let numbers = css
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 3 else { return nil }
        if numbers.count >= 4, numbers[3] == 0 { return nil }
        return NSColor(
            srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1
        )
    }

    // The chrome/engine split, delivered by WebKit: a page crash kills only
    // Apple's WebContent process. Reload and move on; the window never blinks.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Bowser: WebContent process died for webview \(webviewId) — reloading")
        webView.reload()
    }

    // MARK: WKUIDelegate

    // target=_blank / window.open: open a real tab, with opener lineage.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // The popup belongs to the window this page lives in, not to
        // whatever happens to be key.
        guard let host = BrowserWindowController.host(of: webviewId)
            ?? (NSApp.delegate as? AppDelegate)?.currentController
        else { return nil }
        let view = host.openTab(
            configuration: configuration, opener: webviewId, activate: true
        )
        return view.webView
    }
}
