import AppKit
import CBowserHost

// MARK: - C callback thunks
// These MUST be file-scope (nonisolated) functions. A closure literal formed
// inside a @MainActor context gets a hidden dispatch_assert_queue(main) when
// converted to a C function pointer — and Servo's waker legally fires from
// engine threads (e.g. WRRenderBackend), which trapped SIGTRAP at launch.

private func bowserWake(_ ctx: UnsafeMutableRawPointer?) {
    // Any thread. Only enqueue; never touch engine state here.
    DispatchQueue.main.async { bowser_host_spin() }
}

// Delegate callbacks fire during bowser_host_spin, which only runs on the
// main thread; assumeIsolated makes that contract loud if it's ever violated.
// Pointers travel as UInt bits (raw pointers aren't Sendable), and C strings
// are copied before the hop — they're only valid for the duration of the call.
private func bowserFrameReady(_ ctx: UnsafeMutableRawPointer?) {
    let key = UInt(bitPattern: ctx)
    MainActor.assumeIsolated { EngineView.cbFrameReady(key) }
}

private func bowserURLChanged(_ ctx: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let value else { return }
    let key = UInt(bitPattern: ctx)
    let string = String(cString: value)
    MainActor.assumeIsolated { EngineView.cbURLChanged(key, string) }
}

private func bowserTitleChanged(_ ctx: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let value else { return }
    let key = UInt(bitPattern: ctx)
    let string = String(cString: value)
    MainActor.assumeIsolated { EngineView.cbTitleChanged(key, string) }
}

private func bowserLoadStatus(_ ctx: UnsafeMutableRawPointer?, _ value: UInt8) {
    // Unused for now.
}

private func bowserBrainMessage(_ ctx: UnsafeMutableRawPointer?) {
    // Socket thread → only enqueue the pump.
    DispatchQueue.main.async { bowser_brain_pump() }
}

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

    /// C callbacks look views up here (keyed by the ctx pointer's bits);
    /// a torn-down view is simply absent, so late callbacks are no-ops
    /// instead of use-after-free.
    private static var live: [UInt: EngineView] = [:]
    private static var hostStarted = false

    static func ensureHostStarted() {
        guard !hostStarted else { return }
        hostStarted = bowser_host_init(bowserWake, nil)
        guard hostStarted else { return }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bowser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let socketPath = dir.appendingPathComponent("brain.sock").path
        if !socketPath.withCString({ bowser_brain_start($0, bowserBrainMessage, nil) }) {
            NSLog("Bowser: brain socket failed to start at \(socketPath)")
        }
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
        EngineView.live[UInt(bitPattern: ctx)] = self

        let (width, height) = devicePixelSize
        let url = pendingURL
        pendingURL = nil
        webviewId = bowser_webview_create(
            Unmanaged.passUnretained(self).toOpaque(),
            width, height,
            Float(backingScale),
            url,
            ctx,
            bowserFrameReady,
            bowserURLChanged,
            bowserTitleChanged,
            bowserLoadStatus
        )
        if webviewId == 0 {
            EngineView.live.removeValue(forKey: UInt(bitPattern: ctx))
        }
    }

    func tearDown() {
        EngineView.live.removeValue(forKey: UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        if webviewId != 0 {
            bowser_webview_destroy(webviewId)
            webviewId = 0
        }
    }

    // MARK: C callback trampolines (fire during spin, on the main thread)

    fileprivate static func cbFrameReady(_ key: UInt) {
        guard let view = live[key], view.webviewId != 0 else { return }
        let id = view.webviewId
        DispatchQueue.main.async { bowser_webview_paint(id) }
    }

    fileprivate static func cbURLChanged(_ key: UInt, _ value: String) {
        live[key]?.onURLChange?(value)
    }

    fileprivate static func cbTitleChanged(_ key: UInt, _ value: String) {
        live[key]?.onTitleChange?(value)
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
