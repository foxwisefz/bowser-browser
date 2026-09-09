import AppKit
import WebKit
import Darwin

typealias Event = @convention(c) @Sendable (Int64, Int64) -> Void
typealias ABI = @convention(c) () -> Int32
typealias Create = @convention(c) (Int64, Int64, Event) -> UnsafeMutableRawPointer?
typealias Step = @convention(c) (UnsafeMutableRawPointer) -> Void
typealias Read = @convention(c) (UnsafeMutableRawPointer) -> Int64
typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
var running: Experiment?
func receive(_ generation: Int64, _ counter: Int64) {
    MainActor.assumeIsolated {
        guard let experiment = running else { return }
        if experiment.generation == generation { experiment.counter = counter }
        else { experiment.staleEvents += 1 }
    }
}
struct Module {
    let handle: UnsafeMutableRawPointer
    let abi: ABI, create: Create, step: Step, read: Read, destroy: Destroy
    init(_ path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw failure(String(cString: dlerror())) }
        self.handle = handle
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw failure("Missing symbol: " + name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        abi = try symbol("module_abi", ABI.self)
        create = try symbol("module_create", Create.self)
        step = try symbol("module_step", Step.self)
        read = try symbol("module_read", Read.self)
        destroy = try symbol("module_destroy", Destroy.self)
    }
}
func failure(_ text: String) -> NSError { NSError(domain: "NativeModuleExperiment", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
@MainActor final class WeakView { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
@MainActor final class Experiment {
    let directory: URL
    var generation: Int64 = 0, counter: Int64 = 0
    var staleEvents = 0
    var active: (Module, UnsafeMutableRawPointer)?
    var retired: [WeakView] = []
    var swapMS: [Double] = []
    let window: NSWindow
    let web: WKWebView
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760))
    init(_ directory: URL) {
        self.directory = directory
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: NSRect(x: 0, y: 60, width: 1000, height: 700), configuration: config)
        web.autoresizingMask = [.width, .height]
        window = NSWindow(contentRect: container.bounds, styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "Isolated native replacement experiment"
        container.addSubview(web); window.contentView = container
    }
    func check(_ yes: Bool, _ message: String) throws { if !yes { throw failure(message) } }
    func until(_ label: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<750 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let detail = try? await web.evaluateJavaScript("JSON.stringify({url:location.href,ready:document.readyState,video:document.querySelector('video')?{ready:video.readyState,network:video.networkState,paused:video.paused,time:video.currentTime,error:video.error?.message}:null})")
        throw failure("Timed out: " + label + " · " + String(describing: detail))
    }
    func snapshot() async throws -> [String: Any] { try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any] }
    @discardableResult func replace(_ module: Module) -> Bool {
        guard module.abi() == 1 else { return false }
        let saved = active.map { $0.0.read($0.1) } ?? counter
        let next = generation + 1
        guard let pointer = module.create(saved, next, receive) else { return false }
        let start = ProcessInfo.processInfo.systemUptime
        let candidate = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
        // All preparation happens before authority transfers, on the main actor.
        container.addSubview(candidate)
        let previous = active
        generation = next; counter = saved; active = (module, pointer)
        if let (old, pointer) = previous {
            retired.append(WeakView(Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()))
            old.destroy(pointer)
        }
        swapMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        return true
    }
    func run() async throws {
        running = self
        defer {
            if let (module, pointer) = active { module.destroy(pointer) }; active = nil
            web.stopLoading(); window.close(); running = nil
        }
        let v1 = try Module(directory.appendingPathComponent("V1.dylib").path)
        try check(replace(v1), "Initial module failed")
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        web.loadFileURL(directory.appendingPathComponent("fixture.html"), allowingReadAccessTo: directory)
        try await until("page loaded") { (try? await self.web.evaluateJavaScript("!!window.probe")) as? Bool == true }
        _ = try await web.evaluateJavaScript("video.muted=true;video.play().catch(e=>window.playError=String(e));true")
        try await until("playing") { (try? await self.web.evaluateJavaScript("!!window.probe && !video.paused && video.currentTime>0.3")) as? Bool == true }
        _ = try await web.evaluateJavaScript("scrollTo(0,120);true")
        try await until("initial scroll") { (try? await self.web.evaluateJavaScript("scrollY")) as? Int == 120 }
        let initialScroll = try await web.evaluateJavaScript("scrollY") as! Int
        _ = try await web.evaluateJavaScript("video.requestFullscreen().catch(e=>window.fullscreenError=String(e));true")
        try await until("HTML video fullscreen") { (try? await self.web.evaluateJavaScript("document.fullscreenElement===video")) as? Bool == true }
        try await Task.sleep(for: .seconds(1))
        let windowID = window.windowNumber, pageID = ObjectIdentifier(web), keyID = NSApp.keyWindow?.windowNumber
        _ = try await web.evaluateJavaScript("probe.reset();true")
        let before = try await snapshot()
        let loadStart = ProcessInfo.processInfo.systemUptime
        let v2 = try Module(directory.appendingPathComponent("V2.dylib").path)
        let bad = try Module(directory.appendingPathComponent("BAD_ABI.dylib").path)
        let failed = try Module(directory.appendingPathComponent("FAIL_CREATE.dylib").path)
        let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        var expected: Int64 = 0
        for index in 0..<12 {
            let module = index.isMultiple(of: 2) ? v2 : v1
            try check(replace(module), "Valid replacement rejected")
            try check(counter == expected, "Counter checkpoint lost")
            module.step(active!.1)
            expected += index.isMultiple(of: 2) ? 2 : 1
            try check(counter == expected, "Native button behavior did not change")
            let pointer = active!.1, stamp = generation
            try check(!replace(bad), "Incompatible ABI accepted")
            try check(!replace(failed), "Failed preparation accepted")
            try check(active!.1 == pointer && generation == stamp && counter == expected, "Rejected candidate disturbed active module")
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(1100))
        let after = try await snapshot()
        try check(before["token"] as? String == after["token"] as? String, "Page replaced")
        try check(after["samePlayer"] as? Bool == true && after["fullscreen"] as? Bool == true, "Player/fullscreen lost")
        try check(after["paused"] as? Bool == false, "Video paused")
        try check((after["time"] as? Double ?? 0) > (before["time"] as? Double ?? 0), "Playback stalled")
        try check((after["ticks"] as? Int ?? 0) > (before["ticks"] as? Int ?? 0), "JS closure stopped")
        try check((after["interruptions"] as? [String])?.isEmpty == true, "Media interruption")
        try check((after["maxGapMS"] as? Double ?? .infinity) < 250, "Video frame gap >=250ms")
        try check(before["scrollY"] as? Double == after["scrollY"] as? Double, "Scroll changed")
        try check(window.windowNumber == windowID && ObjectIdentifier(web) == pageID && NSApp.keyWindow?.windowNumber == keyID, "Native window/page/focus changed: window=\(window.windowNumber)/\(windowID), page=\(ObjectIdentifier(web) == pageID), focus=\(String(describing: NSApp.keyWindow?.windowNumber))/\(String(describing: keyID)), active=\(NSApp.isActive)")
        try check(counter == expected && staleEvents > 0, "Stale event protection failed: counter=\(counter), expected=\(expected), stale=\(staleEvents)")
        try check(retired.allSatisfy { $0.view == nil }, "Retired module view retained")
        _ = try await web.evaluateJavaScript("document.exitFullscreen();true")
        try await until("exit fullscreen") { (try? await self.web.evaluateJavaScript("!document.fullscreenElement")) as? Bool == true }
        try await until("restore page scroll") { (try? await self.web.evaluateJavaScript("scrollY")) as? Int == initialScroll }
        let restoredScroll = try await web.evaluateJavaScript("scrollY") as! Int
        let result: [String: Any] = ["passed": true, "replacements": 12, "rejectedCandidates": 24,
            "counter": counter, "staleEventsRejected": staleEvents, "retiredViewsReleased": retired.count,
            "swapMS": swapMS, "loadMS": loadMS, "before": before, "after": after,
            "initialScroll": initialScroll, "restoredScroll": restoredScroll, "sameWindowAndWebView": true, "scope": "Ad hoc signed isolated Swift modules; C ABI; retained dylib mappings; local muted HTML fullscreen video. No production updater integration."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        try await Task.sleep(for: .seconds(1))
        // Capture the changed native chrome after fullscreen continuity assertions.
        if let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("native-ui.png"))
        }
    }
}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ExperimentDirectory") as! String)
        Task { @MainActor in
            do { try await Experiment(directory).run() }
            catch {
                try? String(describing: error).write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
                try? JSONSerialization.data(withJSONObject: ["passed": false, "error": String(describing: error)], options: [.prettyPrinted]).write(to: directory.appendingPathComponent("result.json"))
            }
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
