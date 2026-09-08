import AppKit
import WebKit

/// Each saved app has its own process and Dock tile. Never aggregate across profiles.
@MainActor
final class SiteAppBadge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = SiteAppBadge()
    private var titles: [UInt64: String] = [:]
    private var explicit: [UInt64: String] = [:]

    static func allows(_ url: URL?, configuration: SiteAppConfiguration?) -> Bool {
        guard let configuration, url?.scheme == "https",
              let host = url?.host?.lowercased(), let saved = configuration.url.host?.lowercased() else { return false }
        return host == saved || host.hasSuffix("." + saved)
    }

    static func titleBadge(_ title: String) -> String {
        // Only a leading unread marker; dates and numbers in normal titles aren't counts.
        guard let match = title.range(of: #"^\s*[\(\[]([0-9]{1,9}\+?)[\)\]]\s*"#, options: .regularExpression) else { return "" }
        let value = String(title[match]).filter { $0.isNumber || $0 == "+" }
        guard let number = Int(value.replacingOccurrences(of: "+", with: "")), number > 0 else { return "" }
        return number > 999 ? "999+" : value
    }

    func updateTitle(_ title: String, id: UInt64, url: URL?) {
        guard SiteAppConfiguration.current != nil else { return }
        titles[id] = Self.allows(url, configuration: SiteAppConfiguration.current) ? Self.titleBadge(title) : ""
        publish()
    }

    func clear(id: UInt64) {
        titles.removeValue(forKey: id)
        explicit.removeValue(forKey: id)
        if SiteAppConfiguration.current != nil { publish() }
    }

    private func publish() {
        // Multiple windows on the same account can report the same count. Don't sum it.
        let labels = Set(titles.keys).union(explicit.keys).map { explicit[$0] ?? titles[$0] ?? "" }
        NSApp.dockTile.badgeLabel = labels.max(by: { Self.rank($0) < Self.rank($1) }).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func rank(_ value: String) -> Int {
        if value == "•" { return 1 }
        return (Int(value.replacingOccurrences(of: "+", with: "")) ?? 0) * 2
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              Self.allows(webView.url, configuration: SiteAppConfiguration.current),
              SiteAppNotifications.origin(message.frameInfo.request.url) == SiteAppNotifications.origin(webView.url),
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == webView.url?.host?.lowercased(),
              let id = EngineView.live.first(where: { $0.value.webView === webView })?.key,
              let body = message.body as? [String: Any], let label = body["label"] as? String,
              label == "" || label == "•" || label.range(of: #"^[1-9][0-9]{0,2}\+?$"#, options: .regularExpression) != nil else {
            replyHandler(nil, "Badges require this saved app's secure top-level page."); return
        }
        explicit[id] = label // Explicit clearing takes precedence over stale title counts.
        publish()
        replyHandler(true, nil)
    }

    static let script = #"""
    (() => {
      if (!window.isSecureContext) return;
      const send = label => window.webkit.messageHandlers.bowserBadge.postMessage({label}).then(() => undefined);
      Object.defineProperties(navigator, {
        setAppBadge: {configurable: true, value: function(value) {
          if (value === undefined) return send('•');
          let n;
          try { n = Number(value); } catch (e) { return Promise.reject(e); }
          if (!Number.isFinite(n) || n < 0 || n > Number.MAX_SAFE_INTEGER)
            return Promise.reject(new TypeError('Badge count must be a non-negative safe integer'));
          n = Math.floor(n);
          return send(n === 0 ? '' : n > 999 ? '999+' : String(n));
        }},
        clearAppBadge: {configurable: true, value: () => send('')}
      });
    })();
    """#
}
