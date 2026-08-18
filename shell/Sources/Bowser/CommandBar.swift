import AppKit

/// The centered command bar (Spotlight-style): URL, search, or :commands —
/// summoned by ⌘K / ⌘L or the titlebar cloverleaf. Esc or click-away closes.
@MainActor
final class CommandBar: NSObject, NSTextFieldDelegate {
    static let shared = CommandBar()

    private var panel: CommandBarPanel?
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "")
    private weak var target: BrowserWindowController?

    func show(for controller: BrowserWindowController) {
        target = controller
        let panel = ensurePanel()

        // Prefill with the current URL, selected — type to replace.
        field.stringValue = controller.engineView.currentURLString ?? ""
        updateMode()

        guard let window = controller.window else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: window.frame.midX - size.width / 2,
            y: window.frame.minY + window.frame.height * 0.62
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
        effect.material = .popover
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
            field.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        panel.contentView = effect
        panel.invalidateShadow()
        self.panel = panel
        return panel
    }

    @objc private func submitted() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return hide() }

        if text.hasPrefix(":") {
            ChromeSurface.emit([
                "op": "event", "event": "omnibar_command", "text": String(text.dropFirst()),
            ])
        } else {
            target?.loadURL(BrowserWindowController.normalize(text))
        }
        hide()
    }

    func controlTextDidChange(_ obj: Notification) { updateMode() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    private func updateMode() {
        let text = field.stringValue
        guard text.hasPrefix(":") else {
            field.font = .systemFont(ofSize: 17)
            field.textColor = .textColor
            styleEditor(font: .systemFont(ofSize: 17), color: .textColor)
            hint.stringValue = ""
            return
        }
        let name = text.dropFirst().split(separator: " ").first.map(String.init) ?? ""
        if name.isEmpty {
            hint.stringValue = "command"
        } else if let registered = ChromeSurface.commands[name] {
            hint.stringValue = registered
        } else {
            let candidates = ChromeSurface.commands.keys.filter { $0.hasPrefix(name) }.sorted()
            hint.stringValue = candidates.isEmpty ? "unknown command" : candidates.joined(separator: " · ")
        }
        let font = NSFont.monospacedSystemFont(ofSize: 15.5, weight: .medium)
        field.font = font
        field.textColor = .controlAccentColor
        styleEditor(font: font, color: .controlAccentColor)
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

private final class CommandBarPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }
}
