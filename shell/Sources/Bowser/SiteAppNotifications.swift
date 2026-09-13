import AppKit
import WebKit
import UserNotifications

/// Page notifications for running saved apps. This does not implement Web Push.
@MainActor
final class SiteAppNotifications: NSObject, WKScriptMessageHandlerWithReply, UNUserNotificationCenterDelegate {
    static let shared = SiteAppNotifications()
    private var prompting = Set<String>()
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    static func origin(_ url: URL?) -> String? {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        return "https://" + host + (url.port == nil || url.port == 443 ? "" : ":\(url.port!)")
    }

    func start() { center.delegate = self }

    @objc func resetPermissions(_ sender: Any?) {
        let alert = NativeUIHost.alert("notification-reset", [:])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let profile = SiteAppConfiguration.current?.profile else { return }
        do { try SitePermissionStore.shared.reset(profile: profile, kind: "notifications") }
        catch { NativeUIHost.alert("message", ["text": "Couldn’t reset notification permissions."]).runModal() }
    }

    static func effectivePermission(choice: String, authorization: UNAuthorizationStatus) -> String {
        if choice == "block" || authorization == .denied { return "denied" }
        if choice == "allow", authorization == .authorized || authorization == .provisional { return "granted" }
        return "default"
    }
    private func permission(_ origin: String, profile: String) async -> String {
        let status = await center.notificationSettings().authorizationStatus
        let local = SitePermissionStore.shared.decision(profile: profile, origin: origin, kind: "notifications")
        return Self.effectivePermission(choice: local, authorization: status)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard SiteAppConfiguration.current != nil, message.frameInfo.isMainFrame,
              let webView = message.webView,
              let engine = EngineView.live.values.first(where: { $0.webView === webView }),
              engine.profileId == SiteAppConfiguration.current?.profile, let origin = Self.origin(webView.url),
              let frameOrigin = Self.origin(message.frameInfo.request.url), frameOrigin == origin,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == webView.url?.host?.lowercased(),
              let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "Notifications require a secure top-level page."); return
        }
        let profile = engine.profileId
        Task { @MainActor in
            switch op {
            case "permission": replyHandler(await permission(origin, profile: profile), nil)
            case "request":
                var state = await permission(origin, profile: profile)
                let requestKey = profile + "\n" + origin
                if state == "default", !prompting.contains(requestKey) {
                    prompting.insert(requestKey)
                    defer { prompting.remove(requestKey) }
                    let store = SitePermissionStore.shared
                    let revision = store.revision
                    let existing = store.decision(profile: profile, origin: origin, kind: "notifications")
                    let approved = existing == "allow" || NativeUIHost.alert("notification-permission", ["origin": origin]).runModal() == .alertFirstButtonReturn
                    guard Self.origin(webView.url) == origin, EngineView.live[engine.webviewId] === engine,
                          store.revision == revision else { replyHandler("default", nil); return }
                    if approved {
                        do {
                            let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                            guard Self.origin(webView.url) == origin, EngineView.live[engine.webviewId] === engine,
                                  store.revision == revision else { replyHandler("default", nil); return }
                            try store.set(profile: profile, origin: origin, kinds: ["notifications"], decision: "allow")
                            state = allowed ? "granted" : "denied"
                        } catch { replyHandler(nil, "Couldn’t save notification permission."); return }
                    } else {
                        do { try store.set(profile: profile, origin: origin, kinds: ["notifications"], decision: "block") }
                        catch { replyHandler(nil, "Couldn’t save notification permission."); return }
                        state = "denied"
                    }
                }
                replyHandler(state, nil)
            case "show":
                guard await permission(origin, profile: profile) == "granted", Self.origin(webView.url) == origin,
                      let id = body["id"] as? String, id.count <= 100,
                      let document = body["document"] as? String, document.count <= 100 else {
                    replyHandler(nil, "Notification permission is not granted."); return
                }
                let content = UNMutableNotificationContent()
                content.title = String((body["title"] as? String ?? "").prefix(256))
                content.body = String((body["body"] as? String ?? "").prefix(4096))
                if body["silent"] as? Bool != true { content.sound = .default }
                content.userInfo = ["origin": origin, "url": webView.url!.absoluteString,
                                    "document": document, "pageID": id]
                let tag = String((body["tag"] as? String ?? "").prefix(256))
                let identifier = origin + "|" + (tag.isEmpty ? document + ":" + id : tag)
                do {
                    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                    replyHandler(identifier, nil)
                } catch { replyHandler(nil, error.localizedDescription) }
            case "close":
                guard let identifier = body["identifier"] as? String, identifier.hasPrefix(origin + "|") else {
                    replyHandler(nil, "Invalid notification."); return
                }
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                replyHandler(true, nil)
            default: replyHandler(nil, "Unknown notification operation.")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let origin = info["origin"] as? String
        let url = info["url"] as? String
        let document = info["document"] as? String ?? ""
        let id = info["pageID"] as? String ?? ""
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            guard clicked, SiteAppConfiguration.current != nil,
                  let url, let targetURL = URL(string: url), Self.origin(targetURL) == origin else { return }
            NSApp.activate()
            let windows = BrowserWindowController.all
            for window in windows {
                for view in window.tabs where Self.origin(view.webView.url) == origin {
                    let args: [String: Any] = ["document": document, "id": id]
                    if (try? await view.webView.callAsyncJavaScript(
                        "return window.__bowserNotificationClick?.(document, id) === true;",
                        arguments: args, in: nil, contentWorld: .page)) as? Bool == true {
                        window.activate(view)
                        window.window?.makeKeyAndOrderFront(nil)
                        return
                    }
                }
            }
            if let window = windows.first {
                window.loadURL(url)
                window.window?.makeKeyAndOrderFront(nil)
            }
        }
        completionHandler()
    }

    static let script = """
    (() => {
      if (window !== window.top || location.protocol !== 'https:') return;
      const bridge = window.webkit.messageHandlers.bowserNotifications;
      const documentID = crypto.randomUUID();
      const live = new Map();
      let permission = 'default', nextID = 0;
      const send = body => bridge.postMessage(body);
      function emit(n, type) { const event = new Event(type); n.dispatchEvent(event); if (typeof n['on'+type] === 'function') n['on'+type](event); }
      class AppNotification extends EventTarget {
        static get permission() { return permission; }
        static requestPermission(callback) {
          return send({op:'request'}).then(value => { permission=value; callback?.(value); return value; });
        }
        constructor(title, options={}) {
          super();
          if (permission !== 'granted') throw new DOMException('Notification permission is not granted', 'NotAllowedError');
          this.title=String(title); this.body=String(options.body || ''); this.tag=String(options.tag || ''); this.data=options.data;
          const id=String(++nextID); live.set(id, this);
          this._request=send({op:'show', id, document:documentID, title:this.title, body:this.body, tag:this.tag, silent:!!options.silent});
          this._request.then(() => emit(this,'show'), () => { live.delete(id); emit(this,'error'); });
          this._id=id;
        }
        close() { this._request.then(identifier => send({op:'close',identifier})).catch(()=>{}); live.delete(this._id); emit(this,'close'); }
      }
      Object.defineProperty(window, 'Notification', {value:AppNotification, configurable:true});
      window.__bowserNotificationClick = (document, id) => {
        const n = document === documentID && live.get(id);
        if (!n) return false; emit(n,'click'); return true;
      };
      const refresh = () => send({op:'permission'}).then(value => {permission=value;}).catch(()=>{});
      refresh(); window.addEventListener('focus', refresh);
    })();
    """
}
