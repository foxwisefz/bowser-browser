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
        let sender = message.webView
        MainActor.assumeIsolated {
            // Attribute by the message's own webView: when a popup shares
            // the opener's content controller, only ONE relay is registered
            // and it must credit whichever tab actually sent the message.
            guard let id = EngineView.live.first(where: { $0.value.webView === sender })?.key
                ?? view?.webviewId
            else { return }
            switch name {
            case "bowserScriptsReady":
                guard message.frameInfo.isMainFrame, let engine = EngineView.live[id],
                      let expected = body as? String, let url = message.frameInfo.request.url,
                      url.absoluteString == expected else { return }
                engine.dispatchModScripts(frame: message.frameInfo, url: url)
            case "bowserConsole":
                guard let dict = body as? [String: Any] else { return }
                BrainBridge.shared.send([
                    "op": "event", "event": "console", "webview": id,
                    "level": dict["level"] as? String ?? "log",
                    "message": dict["message"] as? String ?? "",
                ])
            case "bowserMediaWarm":
                guard message.frameInfo.isMainFrame,
                      let dict = body as? [String: Any],
                      dict["runtime"] as? String == MediaRecovery.runtime,
                      let engine = EngineView.live[id], !engine.didWarmMediaRecovery
                else { return }
                engine.didWarmMediaRecovery = true
                BrowserWindowController.host(of: id)?.warmTab(id: id, ms: 10_000)
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
    private var faviconGeneration = UUID()
    private var iconCandidates: [[String: Any]] = []
    private var faviconICNSPath: String?
    /// Last sampled page tint. Cached because a tab can be mounted long
    /// after it loaded, and the chrome has to catch up on the spot.
    private(set) var themeColor: NSColor?
    let webView: WKWebView

    private let pageRelay = PageRelay()
    fileprivate var didWarmMediaRecovery = false
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var currentScripts: [ModScript] = []
    private var currentStyles: [String] = []

    // The brain's last-pushed user content. set_user_content only reaches
    // webviews alive at push time — a tab opened later was born UNMODDED
    // (no site payloads, no mod scripts) until the next push
    // (bowser-browser-1af). New views seed from here instead.
    private(set) static var sharedScripts: [ModScript] = []
    private(set) static var sharedStyles: [String] = []
    private static var profileScripts: [String: [ModScript]] = [:]
    private static var profileStyles: [String: [String]] = [:]
    static func content(for profile: String) -> (scripts: [ModScript], styles: [String]) {
        (sharedScripts + (profileScripts[profile] ?? []), sharedStyles + (profileStyles[profile] ?? []))
    }

    /// Same nil/[] semantics as applyUserContent: nil leaves that kind
    /// untouched, [] clears it.
    static func rememberUserContent(scripts: [ModScript]?, styles: [String]?, profile: String? = nil) {
        if let profile {
            if let scripts { profileScripts[profile] = scripts }
            if let styles { profileStyles[profile] = styles }
            return
        }
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
    static let pageTopInset: CGFloat = SiteAppConfiguration.current == nil ? 34 : 0

    /// WebKit's own top content inset (what Safari uses under its toolbar):
    /// the page's viewport starts below the band — position:fixed headers
    /// anchor there instead of hiding under our chrome — while content still
    /// scrolls beneath it. Private API (_topContentInset), so probed once;
    /// without it we fall back to the body margin-top rule.
    /// ON. (It was switched off once on a misdiagnosis: a page squeeze that
    /// was really the reader mod's global stylesheet, and a 32px overflow
    /// that is present with the inset off too.)
    static let usesNativeInset: Bool = {
        let probe = WKWebView(frame: .zero)
        return probe.responds(to: Selector(("_setTopContentInset:")))
            && probe.responds(to: Selector(("_setAutomaticallyAdjustsContentInsets:")))
    }()

    /// Invoke an ObjC setter taking a primitive (no KVC, no NSInvocation).
    private static func callPrivateSetter(_ target: NSObject, _ name: String, bool value: Bool) {
        let sel = Selector((name))
        guard target.responds(to: sel), let imp = target.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, sel, ObjCBool(value))
    }

    private static func callPrivateSetter(_ target: NSObject, _ name: String, double value: CGFloat) {
        let sel = Selector((name))
        guard target.responds(to: sel), let imp = target.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, sel, value)
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, configuration: nil)
    }

    /// Popups (target=_blank) must be created with the configuration WebKit
    /// hands us in createWebViewWith — hence the injectable configuration.
    /// Which profile this webview belongs to (its window's). Popups arrive
    /// with WebKit's configuration — the opener's store — and their window
    /// is the opener's, so the id still matches the store.
    let profileId: String

    init(frame frameRect: NSRect, configuration external: WKWebViewConfiguration?, profile: Profile = .defaultProfile) {
        profileId = profile.id
        let configuration = external ?? {
            let c = WKWebViewConfiguration()
            // The profile's own cookies/logins/storage (default profile =
            // the default store, so pre-profile logins stay put).
            c.websiteDataStore = profile.dataStore
            return c
        }()
        // Media resume after a respawn needs programmatic play().
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // WKWebView disables HTML element fullscreen by default; Safari
        // enables it. Without this, a video's fullscreen button does nothing
        // (bowser-browser-cgt). Public API on macOS 12.3+.
        configuration.preferences.isElementFullscreenEnabled = true
        // macOS exposes PiP through WebKit's preferences SPI (not the iOS
        // configuration property). Guard the selector and avoid unsafe KVC.
        Self.callPrivateSetter(configuration.preferences, "_setAllowsPictureInPictureMediaPlayback:", bool: true)
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        webviewId = Self.nextId
        Self.nextId += 1
        Self.live[webviewId] = self

        pageRelay.view = self
        registerRelay()
        currentScripts = Self.content(for: profileId).scripts
        currentStyles = Self.content(for: profileId).styles
        rebuildUserScripts()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if Self.usesNativeInset {
            // Private setters, called directly: these keys are NOT KVC-coded
            // (setValue:forKey: throws NSUnknownKeyException — it took the
            // engine down on every webview).
            Self.callPrivateSetter(webView, "_setAutomaticallyAdjustsContentInsets:", bool: false)
            Self.callPrivateSetter(webView, "_setTopContentInset:", double: Self.pageTopInset)
            // Public half: CSS viewport units (lvh/svh) know about the band.
            let insets = NSEdgeInsets(top: Self.pageTopInset, left: 0, bottom: 0, right: 0)
            webView.setMinimumViewportInset(insets, maximumViewportInset: insets)
        }
        // Full Safari impersonation: WKWebView's default UA lacks the
        // "Version/x Safari/x" suffix and sites like YouTube Music sniff it.
        webView.customUserAgent = SafariUserAgent.current
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
                SiteAppBadge.shared.updateTitle(title, id: self.webviewId, url: view.url)
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

    private let externalNavigation = ExternalNavigationConsent()

    var currentURLString: String? { webView.url?.absoluteString }

    // MARK: Commands

    static func localFileURL(_ input: String) -> URL? {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    func load(urlString: String) {
        guard let url = Self.localFileURL(urlString) ?? URL(string: urlString) else { return }
        // file:// needs explicit read access to the containing directory or
        // WebKit sandboxes sibling resources — a local page's <video>, css,
        // and images silently fail to load (bowser-browser-vus). Grant the
        // whole directory so a self-contained local page works like it does
        // in Safari.
        if url.isFileURL {
            // Read access is granted to the file's DIRECTORY, computed from
            // the bare path so a #fragment (reveal.js slide anchors etc.)
            // can't corrupt the directory resolution.
            let dir = URL(fileURLWithPath: url.path).deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: dir)
        } else {
            webView.load(URLRequest(url: url))
        }
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
    func applyUserContent(scripts: [ModScript]?, styles: [String]?, reload: Bool) {
        let changed = (scripts != nil && scripts != currentScripts) || (styles != nil && styles != currentStyles)
        if let scripts { currentScripts = scripts }
        if let styles { currentStyles = styles }
        rebuildUserScripts()
        if reload && changed { webView.reload() }
    }

    fileprivate func dispatchModScripts(frame: WKFrameInfo, url: URL) {
        // Verify the WebKit-supplied security origin as well as the request URL.
        let origin = frame.securityOrigin
        guard origin.host.lowercased() == (url.host?.lowercased() ?? ""), origin.protocol == url.scheme else { return }
        for script in currentScripts where script.matches(url) {
            guard let code = ModScript.guardedSource(script.source) else { continue }
            webView.callAsyncJavaScript(code,
                arguments: ["expectedURL": url.absoluteString],
                in: frame, in: script.contentWorld) { _ in }
        }
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
        s.textContent = "body { margin-top: \(EngineView.usesNativeInset ? 0 : Int(EngineView.pageTopInset))px !important; }";
        // The strip under the chrome band is the body's top margin, so it
        // shows the <html> background. Many apps leave <html> transparent
        // (Google AI Studio: body #1f1f1f, html none) and WebKit paints its
        // base gray there — a visible bar. Copy the body's color onto <html>
        // when it is transparent so the band blends into the page.
        var bowserSyncHtmlBg = function () {
          try {
            var html = document.documentElement, body = document.body;
            if (!body) return;
            var hb = getComputedStyle(html).backgroundColor;
            var bb = getComputedStyle(body).backgroundColor;
            var transparent = function (c) { return !c || c === "transparent" || /rgba\\(.*,\\s*0\\)$/.test(c); };
            if (transparent(hb) && !transparent(bb) && html.style.backgroundColor !== bb) {
              html.style.backgroundColor = bb;
            }
          } catch (e) {}
        };
        bowserSyncHtmlBg();
        document.addEventListener("DOMContentLoaded", bowserSyncHtmlBg);
        window.addEventListener("load", bowserSyncHtmlBg);
        // SPAs paint their theme late: keep syncing for a while, then stop.
        var bowserSyncTicks = 0;
        var bowserSyncTimer = setInterval(function () {
          bowserSyncHtmlBg();
          if (++bowserSyncTicks > 20) clearInterval(bowserSyncTimer);
        }, 1500);
        (document.head || document.documentElement).appendChild(s);
      }
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply);
      apply();
    })();
    """

    static let mediaResumeWindowSeconds = 120
    static let mediaHook = MediaRecovery.script

    private func rebuildUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if SiteAppConfiguration.current != nil {
            controller.addUserScript(WKUserScript(source: SiteAppBadge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(source: SiteAppNotifications.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
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
        // Only the dispatcher is registered with WebKit. Site source remains
        // native until the loaded frame's origin has been checked.
        controller.addUserScript(WKUserScript(source: ModScript.ready,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: ModScript.dispatchWorld))
        controller.addUserScript(WKUserScript(source: Self.consoleHook,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ModScript.isolatedWorld))
    }

    /// ITP partitions third-party iframe cookies, so embedded players
    /// (a YouTube embed on a third-party site) can't see the owner's login and
    /// demand sign-in (bowser-browser-yll). One owner, one machine: switch
    /// tracking prevention off on the shared store. SPI via KVC
    /// (_setResourceLoadStatisticsEnabled:), guarded so an OS that drops it
    /// degrades to a no-op instead of crashing. Returns whether it took.
    @discardableResult
    static func disableTrackingPrevention(on store: WKWebsiteDataStore = .default()) -> Bool {
        guard store.responds(to: NSSelectorFromString("_setResourceLoadStatisticsEnabled:")) else {
            NSLog("Bowser: ITP SPI missing — third-party embeds may demand sign-in")
            return false
        }
        store.setValue(false, forKey: "resourceLoadStatisticsEnabled")
        return true
    }

    /// Popups arrive with the OPENER's configuration — its controller
    /// already has these handlers, and a duplicate add() throws an uncaught
    /// NSException: every target=_blank link click aborted the app
    /// (bowser-browser-pi1). Remove-before-add is idempotent, and PageRelay
    /// attributes by message.webView so a shared controller still credits
    /// the right tab.
    private func registerRelay() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bowserConsole")
        controller.removeScriptMessageHandler(forName: "bowserEmit")
        controller.removeScriptMessageHandler(forName: "bowserMediaWarm")
        controller.removeScriptMessageHandler(forName: "bowserScriptsReady", contentWorld: ModScript.dispatchWorld)
        controller.removeScriptMessageHandler(forName: "bowserConsole", contentWorld: ModScript.isolatedWorld)
        controller.removeScriptMessageHandler(forName: "bowserEmit", contentWorld: ModScript.isolatedWorld)
        controller.add(pageRelay, name: "bowserConsole")
        controller.add(pageRelay, name: "bowserEmit")
        controller.add(pageRelay, name: "bowserMediaWarm")
        controller.add(pageRelay, contentWorld: ModScript.dispatchWorld, name: "bowserScriptsReady")
        controller.add(pageRelay, contentWorld: ModScript.isolatedWorld, name: "bowserConsole")
        controller.add(pageRelay, contentWorld: ModScript.isolatedWorld, name: "bowserEmit")
        if SiteAppConfiguration.current != nil {
            controller.removeScriptMessageHandler(forName: "bowserBadge", contentWorld: .page)
            controller.addScriptMessageHandler(SiteAppBadge.shared, contentWorld: .page, name: "bowserBadge")
            controller.removeScriptMessageHandler(forName: "bowserNotifications", contentWorld: .page)
            controller.addScriptMessageHandler(SiteAppNotifications.shared, contentWorld: .page, name: "bowserNotifications")
        }
    }

    func tearDown() {
        SiteAppBadge.shared.clear(id: webviewId)
        EngineView.live.removeValue(forKey: webviewId)
        BrainBridge.shared.send([
            "op": "event", "event": "webview_closed", "webview": webviewId,
        ])
        urlObservation = nil
        titleObservation = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "bowserConsole")
        controller.removeScriptMessageHandler(forName: "bowserEmit")
        controller.removeScriptMessageHandler(forName: "bowserMediaWarm")
        controller.removeScriptMessageHandler(forName: "bowserScriptsReady", contentWorld: ModScript.dispatchWorld)
        controller.removeScriptMessageHandler(forName: "bowserConsole", contentWorld: ModScript.isolatedWorld)
        controller.removeScriptMessageHandler(forName: "bowserEmit", contentWorld: ModScript.isolatedWorld)
        // A sibling sharing this controller (popup lineage) must keep
        // receiving page messages after this tab dies.
        EngineView.live.values
            .first(where: { $0.webView.configuration.userContentController === controller })?
            .registerRelay()
    }

    // MARK: WKNavigationDelegate

    /// What a click on a link should do to the tab strip.
    enum TabIntent {
        /// Navigate the tab that was clicked in — the ordinary case.
        case sameTab
        /// Open a new tab, leave the user where they are (⌘+click).
        case backgroundTab
        /// Open a new tab and switch to it (⌘⇧+click).
        case foregroundTab
    }

    /// ⌘+click = new tab behind, ⌘⇧+click = new tab in front — the same
    /// contract every mac browser ships (bowser-browser-0ia). Pure so it can
    /// be tested without an event loop: WebKit hands us these two facts and
    /// nothing else matters. Only a link ACTIVATION counts — ⌘ is also held
    /// for ⌘R and ⌘←, and a reload must never spawn a tab.
    static func linkClickIntent(
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags
    ) -> TabIntent {
        NavigationPolicy.shared.intent(type: navigationType, modifiers: modifierFlags)
    }

    nonisolated static func shouldOpenExternally(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return !["about", "blob", "data", "file", "http", "https", "javascript"].contains(scheme)
    }

    // A ⌘+click reaches us as an ordinary main-frame navigation: WebKit
    // carries the modifiers but has no opinion about tabs, so without this
    // the link just replaced the page the user meant to keep.
    //
    // The decisionHandler MUST keep its `@MainActor @Sendable` attributes.
    // This is an OPTIONAL protocol requirement, so a signature that doesn't
    // match the SDK's exactly isn't a compile error — it just stops being the
    // witness, gets no @objc thunk, and WebKit's respondsToSelector: check
    // silently skips it. Costed an hour: the method existed, was never called
    // (bowser-browser-0ia).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if Self.shouldOpenExternally(navigationAction.request.url),
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            guard navigationAction.sourceFrame.isMainFrame, let window = webView.window else { return }
            let origin = navigationAction.sourceFrame.securityOrigin
            let source = origin.host.isEmpty ? "This page" : origin.host
            externalNavigation.request(url: url, source: source, window: window)
            return
        }
        // `<a download>` and app-scheme links ask WebKit to download rather
        // than navigate (bowser-browser-9ew).
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        let intent = Self.linkClickIntent(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags
        )
        // targetFrame == nil means WebKit is already on its way to
        // createWebViewWith (target=_blank, window.open) — that path owns the
        // tab, and intercepting here too would open two.
        guard intent != .sameTab,
              navigationAction.targetFrame != nil,
              let url = navigationAction.request.url,
              let host = BrowserWindowController.host(of: webviewId)
                ?? (NSApp.delegate as? AppDelegate)?.currentController
        else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        let view = host.openTab(opener: webviewId, activate: intent == .foregroundTab)
        view.load(urlString: url.absoluteString)
    }

    // A response WebKit can't display (a binary, a file with Content-
    // Disposition: attachment) becomes a download instead of a blank page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        NativeDownloads.shared.attach(download, tab: webviewId, profile: profileId)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        NativeDownloads.shared.attach(download, tab: webviewId, profile: profileId)
    }

    static func uniqueDownloadURL(_ suggested: String) -> URL { NativeDownloads.uniqueURL(suggested) }

    // MARK: - File picker (Safari parity)

    /// `<input type="file">` and the "Choose file" button do NOTHING in a
    /// WKWebView until the app runs the open panel itself (like fullscreen,
    /// downloads and AV1 before it — bowser-browser-fry family).
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        // WK_SWIFT_UI_ACTOR in the SDK: the handler MUST be @MainActor
        // @Sendable or this is not the protocol witness — the compiler only
        // says "nearly matches" and WebKit silently never calls it.
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        faviconGeneration = UUID()
        iconCandidates = []
        faviconICNSPath = nil
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 0,
        ])
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        SiteAppBadge.shared.clear(id: webviewId)
        didWarmMediaRecovery = false
        // An empty path renders the dock's globe, including in existing mods
        // that ignore nil attributes. Never retain the previous page's icon.
        announceFavicon("")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        BrainBridge.shared.send([
            "op": "event", "event": "load_status", "webview": webviewId, "status": 2,
        ])
        // The freeze-frame overlay yields once the on-screen tab has real
        // pixels again (bowser-browser-9qr).
        BrowserWindowController.host(of: webviewId)?.engineDidPaint(self)
        sampleThemeColor()
        captureFavicon()
        SiteAppRuntime.shared.pageFinished(self)
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

    // MARK: Favicon pipeline

    // Use the page's network context first: a separate URLSession can fail
    // even when WebKit loads the icon. Decode SVG, ICO and raster candidates
    // with WebKit, trying the next on failure. No page content is changed.
    nonisolated static let pageFaviconProbe = WebsiteIcon.probe

    func captureFavicon() {
        guard let pageURL = webView.url, pageURL.host != nil else { return }
        let generation = faviconGeneration
        webView.callAsyncJavaScript(Self.pageFaviconProbe, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.faviconGeneration == generation, self.webView.url == pageURL else { return }
            if case .success(let value) = result, let candidates = value as? [[String: Any]], !candidates.isEmpty {
                self.iconCandidates = candidates
                self.resendIconCandidates()
            }
        }
    }

    func resendIconCandidates() {
        guard let url = webView.url else { return }
        guard !iconCandidates.isEmpty else { captureFavicon(); return }
        faviconGeneration = UUID()
        BrainBridge.shared.send(["op": "event", "event": "icon_candidates", "webview": webviewId,
            "generation": faviconGeneration.uuidString, "url": url.absoluteString, "profile": profileId,
            "candidates": iconCandidates,
            "profile_badge": (Profile.find(profileId).avatar?.image ?? NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil))?.tiffRepresentation?.base64EncodedString() ?? ""])
    }

    var appIconData: Data? {
        faviconICNSPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    func acceptIcon(_ message: [String: Any]) {
        guard message["generation"] as? String == faviconGeneration.uuidString,
              message["url"] as? String == webView.url?.absoluteString,
              let path = message["path"] as? String, let icns = message["icns"] as? String else { return }
        let cache = BowserPaths.home.appendingPathComponent("favicons/tiles-v2").standardizedFileURL.path + "/"
        guard URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(cache),
              URL(fileURLWithPath: icns).standardizedFileURL.path.hasPrefix(cache) else { return }
        faviconICNSPath = icns
        iconCandidates = [] // Rediscover on reconnect instead of retaining decoded image payloads.
        announceFavicon(path)
        if let config = SiteAppConfiguration.current, let url = webView.url,
           TabAppBundle.iconKey(url: config.url, profile: config.profile) == TabAppBundle.iconKey(url: url, profile: profileId) {
            NSApp.applicationIconImage = NSImage(contentsOfFile: path)
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
        Task { await Telemetry.shared.record(.crash(.native)) }
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
        // A plain window.open lands in front, but ⌘+click keeps the same
        // stay-put promise it has on an ordinary link.
        let intent = Self.linkClickIntent(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags
        )
        let view = host.openTab(
            configuration: configuration, opener: webviewId,
            activate: intent != .backgroundTab
        )
        return view.webView
    }
}
