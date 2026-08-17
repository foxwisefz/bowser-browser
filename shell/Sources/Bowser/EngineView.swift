import AppKit
import CBowserHost

/// Hosts a Servo webview surface via the bowser-host FFI.
///
/// Threading contract (see bowser_host.h): all bowser_* calls happen on the
/// main thread. C callbacks fire inside bowser_host_spin (main thread), and
/// must never re-enter bowser_* synchronously — paint is bounced through the
/// main queue.
@MainActor
final class EngineView: NSView {
    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((String) -> Void)?

    private var webviewId: UInt64 = 0
    private var pendingURL: String?

    /// C callbacks look views up here; a torn-down view is simply absent,
    /// so late callbacks are no-ops instead of use-after-free.
    private static var live: [UnsafeMutableRawPointer: EngineView] = [:]
    private static var hostStarted = false

    static func ensureHostStarted() {
        guard !hostStarted else { return }
        // Wake may fire on any thread; only enqueue a spin on the main queue.
        let started = bowser_host_init({ _ in
            DispatchQueue.main.async { bowser_host_spin() }
        }, nil)
        hostStarted = started
    }

    static func shutdownHost() {
        guard hostStarted else { return }
        bowser_host_shutdown()
        hostStarted = false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private var devicePixelSize: (UInt32, UInt32) {
        let scale = backingScale
        return (
            UInt32(max(1, bounds.width * scale)),
            UInt32(max(1, bounds.height * scale))
        )
    }

    // MARK: Webview lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, webviewId == 0 else { return }
        EngineView.ensureHostStarted()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        EngineView.live[ctx] = self

        let (width, height) = devicePixelSize
        let url = pendingURL
        pendingURL = nil
        webviewId = bowser_webview_create(
            Unmanaged.passUnretained(self).toOpaque(),
            width, height,
            Float(backingScale),
            url,
            ctx,
            { ctx in MainActor.assumeIsolated { EngineView.cbFrameReady(ctx) } },
            { ctx, value in MainActor.assumeIsolated { EngineView.cbURLChanged(ctx, value) } },
            { ctx, value in MainActor.assumeIsolated { EngineView.cbTitleChanged(ctx, value) } },
            { _, _ in /* load status: unused for now */ }
        )
        if webviewId == 0 {
            EngineView.live.removeValue(forKey: ctx)
        }
    }

    func tearDown() {
        EngineView.live.removeValue(forKey: Unmanaged.passUnretained(self).toOpaque())
        if webviewId != 0 {
            bowser_webview_destroy(webviewId)
            webviewId = 0
        }
    }

    // MARK: C callback trampolines (fire during spin, on the main thread)

    private static func view(for ctx: UnsafeMutableRawPointer?) -> EngineView? {
        guard let ctx else { return nil }
        return live[ctx]
    }

    private static func cbFrameReady(_ ctx: UnsafeMutableRawPointer?) {
        guard let view = view(for: ctx), view.webviewId != 0 else { return }
        let id = view.webviewId
        DispatchQueue.main.async { bowser_webview_paint(id) }
    }

    private static func cbURLChanged(_ ctx: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
        guard let view = view(for: ctx), let value else { return }
        view.onURLChange?(String(cString: value))
    }

    private static func cbTitleChanged(_ ctx: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
        guard let view = view(for: ctx), let value else { return }
        view.onTitleChange?(String(cString: value))
    }

    // MARK: Commands

    func load(urlString: String) {
        guard webviewId != 0 else {
            pendingURL = urlString
            return
        }
        bowser_webview_load(webviewId, urlString)
    }

    @objc func goBack(_ sender: Any?) {
        guard webviewId != 0 else { return }
        bowser_webview_go_back(webviewId)
    }

    @objc func goForward(_ sender: Any?) {
        guard webviewId != 0 else { return }
        bowser_webview_go_forward(webviewId)
    }

    // MARK: Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard webviewId != 0 else { return }
        let (width, height) = devicePixelSize
        bowser_webview_resize(webviewId, width, height)
    }

    // MARK: Input

    private func devicePoint(_ event: NSEvent) -> (Float, Float) {
        let local = convert(event.locationInWindow, from: nil)
        let scale = backingScale
        return (Float(local.x * scale), Float(local.y * scale))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard webviewId != 0 else { return }
        let (x, y) = devicePoint(event)
        bowser_webview_mouse_move(webviewId, x, y)
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(event, button: 0, down: true)
    }
    override func mouseUp(with event: NSEvent) { sendButton(event, button: 0, down: false) }
    override func rightMouseDown(with event: NSEvent) { sendButton(event, button: 2, down: true) }
    override func rightMouseUp(with event: NSEvent) { sendButton(event, button: 2, down: false) }
    override func otherMouseDown(with event: NSEvent) { sendButton(event, button: 1, down: true) }
    override func otherMouseUp(with event: NSEvent) { sendButton(event, button: 1, down: false) }

    private func sendButton(_ event: NSEvent, button: UInt8, down: Bool) {
        guard webviewId != 0 else { return }
        let (x, y) = devicePoint(event)
        bowser_webview_mouse_button(webviewId, button, down, x, y)
    }

    override func scrollWheel(with event: NSEvent) {
        guard webviewId != 0 else { return }
        let (x, y) = devicePoint(event)
        if event.hasPreciseScrollingDeltas {
            let scale = backingScale
            bowser_webview_wheel(
                webviewId,
                Double(event.scrollingDeltaX * scale),
                Double(event.scrollingDeltaY * scale),
                0, x, y
            )
        } else {
            bowser_webview_wheel(webviewId, Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), 1, x, y)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard webviewId != 0 else { return }
        bowser_webview_key(webviewId, true, event.characters, event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        guard webviewId != 0 else { return }
        bowser_webview_key(webviewId, false, event.characters, event.keyCode)
    }
}
