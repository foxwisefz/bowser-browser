import AppKit
import SwiftUI
import WebKit

/// One window, N in-memory webviews (bowser-browser-cdd). There is no native
/// tab mechanism anywhere: no tab groups, no `addTabbedWindow`, no tab bar to
/// hide. Every tab is an `EngineView` living in `tabs`; exactly one is mounted
/// in the content container at a time and the rest sit DETACHED — full DOM,
/// history and JS state in memory, just not in the view hierarchy. Switching a
/// tab is a subview swap. The dock (a mod-owned edge surface) is the only tab
/// UI, and the tab_opened/tab_activated/webview_closed events it consumes are
/// unchanged.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    /// Every live window, in creation order. Strong: this is what owns them.
    private(set) static var all: [BrowserWindowController] = []

    /// The window holding a given webview, if any.
    static func host(of webviewId: UInt64) -> BrowserWindowController? {
        all.first { controller in controller.tabs.contains { $0.webviewId == webviewId } }
    }

    /// Every webview this window owns, in open order — mounted or not.
    private(set) var tabs: [EngineView] = []
    /// The mounted one. A window always has a tab: closing the last closes it.
    private(set) var activeTab: EngineView!

    /// The mount point. The active tab fills it; the chrome band rides on top.
    private let container = NSView()
    private var band: BandScrimView!
    private var clusterHosting: NSHostingView<AnyView>?
    private let titleLabel = NSTextField(labelWithString: "")

    convenience init() {
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
        // The whole point: AppKit must never group our windows into tabs.
        // Without this, ⌘T/window-merge hands us a tab bar we then have to
        // fight — the whack-a-mole this bead exists to end.
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        // Owner's call: no traffic lights — ⌘+K takes the corner. Close via
        // Cmd+W/Cmd+Q as usual.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        self.init(window: window)

        window.delegate = self
        container.autoresizingMask = [.width, .height]
        window.contentView = container

        // The chrome band: a click-through scrim OVER the page — the page's
        // own background (and content scrolling up) shows through. True
        // blur-over-webview isn't possible (WKWebView renders out of
        // process), so a translucent adaptive wash is the mechanism.
        let band = BandScrimView()
        band.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(band)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: container.topAnchor),
            band.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            band.heightAnchor.constraint(equalToConstant: EngineView.pageTopInset),
        ])
        self.band = band

        // The whole chrome: a cloverleaf cluster next to the traffic lights,
        // living in the REAL titlebar view (the traffic lights' superview) —
        // plain view, obeys constraints; page starts below the band so
        // nothing ever collides. The band still takes the page's theme tint.
        let hosting = NSHostingView(rootView: AnyView(clusterView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            titlebar.addSubview(hosting)
            titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.lineBreakMode = .byTruncatingTail
            // A long title must truncate, not dictate the window's minimum
            // width through compression resistance.
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.alignment = .center
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: 15),
                // titlebar view is 28pt but the band is 34 — +3 centers in the band
                hosting.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor, constant: 3),
                hosting.heightAnchor.constraint(equalToConstant: 24),
                // Fixed width: a content-sized hosting view GROWS under the
                // cursor on hover, flipping hover off/on in a jank loop and
                // moving the chevrons mid-click.
                hosting.widthAnchor.constraint(equalToConstant: 340),
                titleLabel.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor, constant: 3),
                titleLabel.widthAnchor.constraint(
                    lessThanOrEqualTo: titlebar.widthAnchor, multiplier: 0.45),
            ])
        }
        clusterHosting = hosting

        Self.all.append(self)
        ChromeSurface.register(self)

        // A window is never tabless: it arrives with its first webview.
        openTab(opener: (NSApp.delegate as? AppDelegate)?.currentWebviewId)
    }

    // MARK: - Tabs

    /// Create a webview owned by this window. It starts DETACHED — the state
    /// exists, nothing is on screen — and is mounted only if `activate`.
    @discardableResult
    func openTab(
        configuration: WKWebViewConfiguration? = nil,
        opener: UInt64? = nil,
        activate shouldActivate: Bool = true
    ) -> EngineView {
        // Born at the mount size so a background tab lays out for the real
        // viewport instead of loading into a 0×0 window.
        let view = EngineView(frame: container.bounds, configuration: configuration)
        view.autoresizingMask = [.width, .height]
        wire(view)
        tabs.append(view)

        // Emit BEFORE it can be mounted: consumers must see tab_opened
        // before the first tab_activated for this webview.
        var opened: [String: Any] = [
            "op": "event", "event": "tab_opened", "webview": view.webviewId,
        ]
        if let opener { opened["opener"] = opener } else { opened["opener"] = NSNull() }
        BrainBridge.shared.send(opened)

        if shouldActivate { activate(view) }
        return view
    }

    /// Mount a tab as the visible content: unmount the old one (it keeps
    /// living, detached), mount this one under the band.
    func activate(_ view: EngineView) {
        guard tabs.contains(where: { $0 === view }) else { return }
        if activeTab !== view {
            activeTab?.removeFromSuperview()
            view.frame = container.bounds
            container.addSubview(view, positioned: .below, relativeTo: band)
            activeTab = view
            // The old first responder just left the hierarchy — hand the
            // keyboard to the page that's actually on screen.
            window?.makeFirstResponder(view.webView)
            adoptChrome(from: view)
        }
        BrainBridge.shared.send([
            "op": "event", "event": "tab_activated", "webview": view.webviewId,
        ])
    }

    @discardableResult
    func activateTab(id: UInt64) -> Bool {
        guard let view = tabs.first(where: { $0.webviewId == id }) else { return false }
        activate(view)
        return true
    }

    /// Close one tab. The window goes with the last one.
    func closeTab(_ view: EngineView) {
        guard let index = tabs.firstIndex(where: { $0 === view }) else { return }
        tabs.remove(at: index)
        view.removeFromSuperview()
        view.tearDown()

        guard !tabs.isEmpty else {
            window?.close()
            return
        }
        if activeTab === view {
            activeTab = nil
            activate(tabs[min(index, tabs.count - 1)])
        }
    }

    func closeTab(id: UInt64) {
        guard let view = tabs.first(where: { $0.webviewId == id }) else { return }
        closeTab(view)
    }

    /// Window chrome follows the mounted tab only — background tabs are free
    /// to retitle and repaint themselves without touching what's on screen.
    private func wire(_ view: EngineView) {
        view.onTitleChange = { [weak self, weak view] title in
            guard let self, let view, self.activeTab === view else { return }
            self.applyTitle(title)
        }
        view.onURLChange = { _ in }
        view.onThemeColor = { [weak self, weak view] color in
            guard let self, let view, self.activeTab === view else { return }
            self.applyThemeColor(color)
        }
    }

    private func adoptChrome(from view: EngineView) {
        applyTitle(view.webView.title ?? "")
        applyThemeColor(view.themeColor)
    }

    private func applyTitle(_ title: String) {
        window?.title = title.isEmpty ? "Bowser" : title
        titleLabel.stringValue = title
    }

    private func applyThemeColor(_ color: NSColor?) {
        guard let window else { return }
        window.backgroundColor = color ?? .windowBackgroundColor
        if let color, let rgb = color.usingColorSpace(.sRGB) {
            let luminance =
                0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        } else {
            window.appearance = nil
        }
    }

    // MARK: - Chrome

    private func clusterView() -> some View {
        CmdCluster(
            openBar: { [weak self] in
                guard let self else { return }
                CommandBar.shared.show(for: self)
            },
            goBack: { [weak self] in self?.activeTab?.webView.goBack() },
            goForward: { [weak self] in self?.activeTab?.webView.goForward() },
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
        activeTab?.load(urlString: url)
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

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        ChromeSurface.unregister(self)
        Self.all.removeAll { $0 === self }
        for tab in tabs { tab.tearDown() }
        tabs = []
        activeTab = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let id = activeTab?.webviewId else { return }
        BrainBridge.shared.send([
            "op": "event", "event": "tab_activated", "webview": id,
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
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
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

/// Translucent adaptive wash over the page top; fully click-through so the
/// page under it stays interactive. Alpha is the transparency dial.
final class BandScrimView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor =
            NSColor.windowBackgroundColor.withAlphaComponent(0.42).cgColor
    }

    // Page content is transform-shifted below the band, so nothing
    // interactive lives under it — the band can own its clicks and act
    // as the window's drag handle. Edge margins stay free for the
    // window's resize zones (grabbing them here made the shell
    // unresizable from the top).
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let margin: CGFloat = 7
        if local.y >= bounds.height - margin
            || local.x <= margin
            || local.x >= bounds.width - margin {
            return nil // let AppKit's edge-resize zones have it
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
