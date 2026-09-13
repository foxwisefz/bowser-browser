import AppKit
import BowserSurfaceKit

@MainActor final class CommandBar: NSObject {
    static let shared = CommandBar()
    typealias TabCandidate = CommandPaletteState.TabCandidate
    typealias Result = CommandPaletteState.Result
    static func suggestions(query: String, tabs: [TabCandidate], profile: String, active: UInt64?) -> [Result] {
        PaletteSuggestions.suggestions(query: query, tabs: tabs, profile: profile, active: active)
    }
    var results: [Result] { state.results }
    private let state = CommandPaletteState()
    private var context: BrowserScreenContext?
    private var panel: CommandBarPanel?
    private weak var target: BrowserWindowController?
    func show(for controller: BrowserWindowController) {
        guard SiteAppConfiguration.current == nil else { return }
        target = controller
        let panel = ensurePanel()
        state.query = ""; state.selected = 0
        state.profile = controller.profile.id; state.active = controller.activeTab?.webviewId
        state.placeholder = controller.activeTab?.currentURLString ?? "Search, address, or :command"
        state.refresh()
        guard let window = controller.window else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - size.width / 2,
            y: max(window.screen?.visibleFrame.minY ?? 0, window.frame.maxY - 100 - size.height)))
        panel.makeKeyAndOrderFront(nil)
        state.focus()
    }
    func hide() { panel?.orderOut(nil) }
    private func ensurePanel() -> CommandBarPanel {
        if let panel { return panel }
        let panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 58),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.onDismiss = { [weak self] in self?.hide() }
        state.dismiss = { [weak self] in self?.hide() }
        state.choose = { [weak self] in self?.choose($0) }
        state.command = { [weak self] text in
            ChromeSurface.emit(["op": "event", "event": "omnibar_command", "text": text,
                "profile": self?.target?.profile.id ?? "default", "webview": self?.target?.activeTab?.webviewId ?? 0])
        }
        state.commands = { [weak self] in ChromeSurface.commands(for: self?.target?.profile.id ?? "default") }
        state.tabs = {
            BrowserWindowController.all.flatMap { controller in controller.tabs.map {
                TabCandidate(id: $0.webviewId, title: $0.webView.title ?? "", url: $0.currentURLString ?? "",
                    profile: controller.profile.id, favicon: $0.faviconPath)
            } }
        }
        state.resize = { [weak panel] height in
            guard let panel else { return }; let frame = panel.frame
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
        }
        let context = BrowserScreenContext(kind: "palette", model: state)
        self.context = context; BrowserScreenContext.contexts[context.id] = context
        let slot = NativeModuleSlot(fallback: CommandPaletteRenderer(state: state), kind: .surfaces)
        slot.setSnapshot(try! JSONSerialization.data(withJSONObject: ["screen": context.id]))
        panel.contentView = slot
        self.panel = panel
        return panel
    }
  func choose(_ result: Result) {
    guard let target else { return hide() }
    if let tab = result.tab {
      guard let controller = BrowserWindowController.host(of: tab.id),
        controller.profile.id == target.profile.id
      else {
        state.refresh()
        return
      }
      hide()
      controller.activateTab(id: tab.id)
      controller.window?.makeKeyAndOrderFront(nil)
    } else {
      hide()
      (NSApp.delegate as? AppDelegate)?.openTab(
        url: BrowserWindowController.normalize(result.query), activate: true,
        profile: target.profile.id)
    }
  }

}
private final class CommandBarPanel: NSPanel {
  var onDismiss: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func resignKey() {
    super.resignKey()
    onDismiss?()
  }
}
