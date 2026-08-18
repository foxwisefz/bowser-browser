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
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        webviewId = Self.nextId
        Self.nextId += 1
        Self.live[webviewId] = self

        pageRelay.view = self
        configuration.userContentController.add(pageRelay, name: "bowserConsole")
        configuration.userContentController.add(pageRelay, name: "bowserEmit")
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
