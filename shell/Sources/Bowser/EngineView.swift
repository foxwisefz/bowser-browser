import AppKit

/// Hosts the Servo rendering surface (via the bowser-host FFI).
/// Currently a stub: dark placeholder until the C bridge lands.
@MainActor
final class EngineView: NSView {
    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((String) -> Void)?

    private let placeholder = NSTextField(labelWithString: "engine surface pending")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    func load(urlString: String) {
        // TODO(bowser-browser-kid): forward to bowser-host FFI.
        placeholder.stringValue = "would load: \(urlString)"
        onURLChange?(urlString)
    }

    @objc func goBack(_ sender: Any?) {
        // TODO(bowser-browser-kid): FFI history navigation.
    }

    @objc func goForward(_ sender: Any?) {
        // TODO(bowser-browser-kid): FFI history navigation.
    }

    func tearDown() {
        // TODO(bowser-browser-kid): destroy the webview via FFI.
    }
}
