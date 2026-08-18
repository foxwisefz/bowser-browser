import AppKit
import SwiftUI
import WebKit

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) var engineView: EngineView!
    private var clusterHosting: NSHostingView<AnyView>?
    var onClose: (() -> Void)?

    convenience init(configuration: WKWebViewConfiguration? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        if let saved = UserDefaults.standard.string(forKey: "BowserWindowFrame") {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }
        window.title = "Bowser"
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "bowser-browser"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        self.init(window: window)

        engineView = EngineView(frame: .zero, configuration: configuration)
        window.delegate = self
        window.contentView = engineView

        // The whole chrome: a cloverleaf cluster next to the traffic lights,
        // living in the REAL titlebar view (the traffic lights' superview) —
        // plain view, obeys constraints; page starts below the band so
        // nothing ever collides. The band still takes the page's theme tint.
        let hosting = NSHostingView(rootView: AnyView(clusterView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            titlebar.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: 100),
                hosting.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor, constant: 1),
                hosting.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        clusterHosting = hosting

        engineView.onTitleChange = { [weak window] title in
            window?.title = title.isEmpty ? "Bowser" : title
        }
        engineView.onURLChange = { _ in }
        engineView.onThemeColor = { [weak window] color in
            guard let window else { return }
            let resolved = color ?? .windowBackgroundColor
            window.backgroundColor = resolved
            if let color, let rgb = color.usingColorSpace(.sRGB) {
                let luminance =
                    0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
            } else {
                window.appearance = nil
            }
        }

        ChromeSurface.register(self)
    }

    private func clusterView() -> some View {
        CmdCluster(
            openBar: { [weak self] in
                guard let self else { return }
                CommandBar.shared.show(for: self)
            },
            goBack: { [weak self] in self?.engineView.webView.goBack() },
            goForward: { [weak self] in self?.engineView.webView.goForward() },
            modClick: { id in
                ChromeSurface.emit(["op": "event", "event": "chrome_click", "id": id])
            }
        )
    }

    func focusOmnibar() {
        CommandBar.shared.show(for: self)
    }

    @objc func focusOmnibarAction(_ sender: Any?) {
        focusOmnibar()
    }

    func loadURL(_ url: String) {
        engineView.load(urlString: url)
    }

    /// Mod buttons render inside the hover cluster now; rebuild it.
    func syncModButtons() {
        clusterHosting?.rootView = AnyView(clusterView())
    }

    // Bare words search; things that look like URLs get https://.
    static func normalize(_ input: String) -> String {
        if input.contains("://") { return input }
        if input.contains(".") && !input.contains(" ") { return "https://\(input)" }
        let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return "https://duckduckgo.com/?q=\(query)"
    }

    func windowWillClose(_ notification: Notification) {
        ChromeSurface.unregister(self)
        engineView.tearDown()
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        BrainBridge.shared.send([
            "op": "event", "event": "tab_activated", "webview": engineView.webviewId,
        ])
    }

    private func persistWindowState() {
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "BowserWindowFrame")
        }
    }

    func windowDidMove(_ notification: Notification) { persistWindowState() }
    func windowDidEndLiveResize(_ notification: Notification) { persistWindowState() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "BowserWasFullscreen")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "BowserWasFullscreen")
    }
}

/// The titlebar cluster: cloverleaf always visible; back/forward and mod
/// buttons fade in on hover. Regular key window titlebar — hover is
/// reliable here, unlike non-activating panels.
private struct CmdCluster: View {
    let openBar: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let modClick: (String) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: openBar) {
                // Keycap-style badge: outlined, rounded face, like a
                // keyboard shortcut printed on the chrome.
                Text("⌘+K")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                Color(red: 0.83, green: 0.65, blue: 0.13).opacity(0.95),
                                lineWidth: 1.2
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Command bar (⌘K)")
            if hovering {
                clusterButton("chevron.left", action: goBack)
                clusterButton("chevron.right", action: goForward)
                ForEach(ChromeSurface.buttons, id: \.id) { button in
                    clusterButton(button.symbol ?? "puzzlepiece.extension") {
                        modClick(button.id)
                    }
                    .help(button.title)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func clusterButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
