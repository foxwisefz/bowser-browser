import AppKit
import WebKit

/// Console relay: pages' console.* calls arrive here and flow to the brain.
/// Separate object so the user content controller never retains EngineView.
private final class ConsoleRelay: NSObject, WKScriptMessageHandler {
    weak var view: EngineView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let id = view?.webviewId else { return }
            BrainBridge.shared.send([
                "op": "event", "event": "console", "webview": id,
                "level": body["level"] as? String ?? "log",
                "message": body["message"] as? String ?? "",
            ])
        }
    }
}

/// The engine surface (ADR 0008): a WKWebView per tab. WebKit owns input,
/// rendering, and process isolation; this class owns identity, user content,
/// and event flow to the brain.
@MainActor
final class EngineView: NSView, WKNavigationDelegate {
    private(set) static var live: [UInt64: EngineView] = [:]
    private static var nextId: UInt64 = 1

    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((String) -> Void)?

    private(set) var webviewId: UInt64 = 0
    let webView: WKWebView

    private let consoleRelay = ConsoleRelay()
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
    })();
    """

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // cookies/storage persist
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        webviewId = Self.nextId
        Self.nextId += 1
        Self.live[webviewId] = self

        consoleRelay.view = self
        configuration.userContentController.add(consoleRelay, name: "bowserConsole")
        rebuildUserScripts()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
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

    private func rebuildUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: Self.consoleHook,
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
    }

    // The chrome/engine split, delivered by WebKit: a page crash kills only
    // Apple's WebContent process. Reload and move on; the window never blinks.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Bowser: WebContent process died for webview \(webviewId) — reloading")
        webView.reload()
    }
}
