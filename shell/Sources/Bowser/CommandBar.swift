import AppKit

/// The centered command bar (Spotlight-style): URL, search, or :commands —
/// summoned by ⌘K / ⌘L or the titlebar cloverleaf. Esc or click-away closes.
@MainActor
final class CommandBar: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
  static let shared = CommandBar()

  private var panel: CommandBarPanel?
  private let field = NSTextField()
  private let hint = NSTextField(labelWithString: "")
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private(set) var results: [Result] = []

  struct TabCandidate: Equatable {
    let id: UInt64
    let title: String
    let url: String
    let profile: String
    var favicon: String? = nil
  }
  struct Result: Equatable {
    let tab: TabCandidate?
    let query: String
    var title: String {
      tab.map { $0.title.isEmpty ? ($0.url.isEmpty ? "New Tab" : $0.url) : $0.title }
        ?? "Open or search: \(query)"
    }
    var detail: String { tab.map { "Switch to tab · \($0.url)" } ?? "Open in a new tab" }
  }

  static func suggestions(query: String, tabs: [TabCandidate], profile: String, active: UInt64?)
    -> [Result]
  {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.hasPrefix(":") else { return [] }
    let needle = query.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
    let matches = tabs.enumerated().compactMap { index, tab -> (Int, Int, TabCandidate)? in
        guard tab.profile == profile, !query.isEmpty || tab.id != active else { return nil }
      let title = tab.title.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      let url = tab.url.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      guard tokens.allSatisfy({ (title + " " + url).contains($0) }) else { return nil }
      let score =
        title == needle || url == needle
        ? 0 : (title.hasPrefix(needle) || (URL(string: url)?.host ?? "").hasPrefix(needle) ? 1 : 2)
      return (score, index, tab)
    }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    var results = matches.map { Result(tab: $0.2, query: query) }
    if !query.isEmpty { results.append(Result(tab: nil, query: query)) }
    return results
  }
  private weak var target: BrowserWindowController?

  func show(for controller: BrowserWindowController) {
    guard SiteAppConfiguration.current == nil else { return }
    target = controller
    let panel = ensurePanel()

    // Launcher semantics: empty field, current URL as placeholder.
    field.stringValue = ""
    field.placeholderString =
      controller.activeTab?.currentURLString
      ?? "Search, address, or :command"
    updateMode()

    guard let window = controller.window else { return }
    let size = panel.frame.size
    let origin = NSPoint(
      x: window.frame.midX - size.width / 2,
      y: max(window.screen?.visibleFrame.minY ?? 0, window.frame.maxY - 100 - size.height)
    )
    panel.setFrameOrigin(origin)
    panel.makeKeyAndOrderFront(nil)
    field.becomeFirstResponder()
    field.currentEditor()?.selectAll(nil)
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func ensurePanel() -> CommandBarPanel {
    if let panel { return panel }

    let panel = CommandBarPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 58),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.onDismiss = { [weak self] in self?.hide() }

    let effect = NSVisualEffectView(frame: panel.contentLayoutRect)
    effect.material = .hudWindow  // glassier than .popover — more of the
    // page shows through the bar
    effect.state = .active
    effect.blendingMode = .behindWindow
    effect.maskImage = Self.roundedMask(radius: 14)
    effect.autoresizingMask = [.width, .height]

    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 17)
    field.placeholderString = "Search, address, or :command"
    field.delegate = self
    field.target = self
    field.action = #selector(submitted)
    field.translatesAutoresizingMaskIntoConstraints = false

    hint.font = .systemFont(ofSize: 10.5, weight: .semibold)
    hint.textColor = .secondaryLabelColor
    hint.translatesAutoresizingMaskIntoConstraints = false

    effect.addSubview(field)
    effect.addSubview(hint)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
      field.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -10),
      field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
      hint.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
      hint.centerYAnchor.constraint(equalTo: field.centerYAnchor),
    ])
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
    table.headerView = nil
    table.rowHeight = 48
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(resultClicked)
    table.setAccessibilityLabel("Tabs and navigation results")
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
      scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
      scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 58),
      scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
    ])
    panel.contentView = effect
    panel.invalidateShadow()
    self.panel = panel
    return panel
  }

  @objc private func submitted() {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if results.indices.contains(table.selectedRow), !text.hasPrefix(":") {
      choose(results[table.selectedRow])
      return
    }
    guard !text.isEmpty else { return hide() }

    hide()  // first — the bar is a panel; give the window back the focus
    if text.hasPrefix(":") {
      ChromeSurface.emit([
        "op": "event", "event": "omnibar_command", "text": String(text.dropFirst()),
        "profile": target?.profile.id ?? "default", "webview": target?.activeTab?.webviewId ?? 0,
      ])
    } else if let delegate = NSApp.delegate as? AppDelegate {
      // Launcher semantics: entering a site opens a NEW tab, switched to.
      delegate.openTab(
        url: BrowserWindowController.normalize(text), activate: true, profile: target?.profile.id)
    }
  }

  func controlTextDidChange(_ obj: Notification) { updateMode() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      hide()
      return true
    }
    if selector == #selector(NSResponder.moveDown(_:))
      || selector == #selector(NSResponder.moveUp(_:))
    {
      guard !results.isEmpty else { return true }
      let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let index = max(0, min(results.count - 1, table.selectedRow + delta))
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
      return true
    }
    return false
  }

  private func updateMode() {
    refreshResults()
    let text = field.stringValue
    guard text.hasPrefix(":") else {
      field.font = .systemFont(ofSize: 17)
      field.textColor = .textColor
      styleEditor(font: .systemFont(ofSize: 17), color: .textColor)
      hint.stringValue = ""
      return
    }
    let commands = ChromeSurface.commands(for: target?.profile.id ?? "default")
    let name = text.dropFirst().split(separator: " ").first.map(String.init) ?? ""
    if name.isEmpty {
      hint.stringValue = "command"
    } else if let registered = commands[name] {
      hint.stringValue = registered
    } else {
      let candidates = commands.keys.filter { $0.hasPrefix(name) }.sorted()
      hint.stringValue =
        candidates.isEmpty ? "unknown command" : candidates.joined(separator: " · ")
    }
    let font = NSFont.monospacedSystemFont(ofSize: 15.5, weight: .medium)
    field.font = font
    field.textColor = .controlAccentColor
    styleEditor(font: font, color: .controlAccentColor)
  }

  private func refreshResults() {
    guard let target, let panel else { return }
    let tabs = BrowserWindowController.all.flatMap { controller in
      controller.tabs.map {
        TabCandidate(
          id: $0.webviewId, title: $0.webView.title ?? "", url: $0.currentURLString ?? "",
          profile: controller.profile.id, favicon: $0.faviconPath)
      }
    }
    results = Self.suggestions(
      query: field.stringValue, tabs: tabs, profile: target.profile.id,
      active: target.activeTab?.webviewId)
    table.reloadData()
    if !results.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    scroll.isHidden = results.isEmpty
    let height = 58 + (results.isEmpty ? 0 : CGFloat(min(results.count, 8)) * 48 + 8)
    let frame = panel.frame
    panel.setFrame(
      NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
      display: true)
    table.tableColumns.first?.width = frame.width - 20
  }

  @objc private func resultClicked() {
    guard results.indices.contains(table.clickedRow) else { return }
    choose(results[table.clickedRow])
  }

  func choose(_ result: Result) {
    guard let target else { return hide() }
    if let tab = result.tab {
      guard let controller = BrowserWindowController.host(of: tab.id),
        controller.profile.id == target.profile.id
      else {
        refreshResults()
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

  func numberOfRows(in tableView: NSTableView) -> Int { results.count }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    CommandResultRow()
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let result = results[row]
    let cell = NSTableCellView()
    let title = NSTextField(labelWithString: result.title)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    let detail = NSTextField(labelWithString: result.detail)
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingMiddle
    let icon = NSImageView()
    icon.image =
      result.tab?.favicon.flatMap { NSImage(contentsOfFile: $0) }
      ?? NSImage(
        systemSymbolName: result.tab == nil ? "magnifyingglass" : "globe",
        accessibilityDescription: nil)
    icon.imageScaling = .scaleProportionallyUpOrDown
    for view in [icon, title, detail] {
      view.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(view)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 24),
      icon.heightAnchor.constraint(equalToConstant: 24),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
      title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
      title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
    ])
    cell.textField = title
    cell.imageView = icon
    return cell
  }

  private func styleEditor(font: NSFont, color: NSColor) {
    guard let editor = field.currentEditor() as? NSTextView else { return }
    editor.font = font
    editor.textColor = color
  }

  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

private final class CommandResultRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
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
