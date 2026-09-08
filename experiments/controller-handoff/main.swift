import AppKit
import WebKit

/// Opt-in experiment using the production EngineView and BrainBridge, but
/// disposable Python controllers rather than the complete Elixir backend.
@MainActor
final class ControllerHandoffExperiment {
    var failures: [String] = []
    func require(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
    @MainActor
    func testControllerReplacementPreservesLiveVideo() async throws {
        let home = BowserPaths.home
        guard home.path.hasPrefix("/tmp/bowser-handoff.") || home.path.hasPrefix("/private/tmp/bowser-handoff.") else {
            throw NSError(domain: "NonFixtureHome", code: 1)
        }
        let repo = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "BowserExperimentRepo") as! String)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "Bowser — isolated controller handoff experiment"
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: config)
        engine.autoresizingMask = [.width, .height]
        window.contentView = engine
        window.makeKeyAndOrderFront(nil)
        app.activate()
        let page = home.appendingPathComponent("fixture.html")
        try Self.html.write(to: page, atomically: true, encoding: .utf8)
        engine.load(urlString: page.absoluteString)
        BrainBridge.shared.start()
        var child: Process?
        defer {
            child?.terminate()
            engine.tearDown()
            window.close()
        }
        try await until("video playback") {
            (try? await engine.webView.evaluateJavaScript("!!window.probe && !video.paused && video.currentTime > 0.5")) as? Bool == true
        }
        window.toggleFullScreen(nil)
        try await until("native fullscreen") { window.styleMask.contains(.fullScreen) }
        // Wait for the native transition to finish before measuring video frames.
        try await Task.sleep(for: .seconds(2))
        window.makeKeyAndOrderFront(nil)
        app.activate()
        try await until("foreground fixture window") { window.isKeyWindow && app.isActive }
        let windowNumber = window.windowNumber
        let viewIdentity = ObjectIdentifier(engine.webView)
        let hostPID = ProcessInfo.processInfo.processIdentifier
        let token = try await engine.webView.evaluateJavaScript("probe.token") as! String
        var samples: [[String: Any]] = []
        var controllerPIDs = Set<Int32>()
        for generation in 1...11 {
            if generation == 7 {
                window.toggleFullScreen(nil)
                try await until("exit native fullscreen before HTML test") { !window.styleMask.contains(.fullScreen) }
                try await Task.sleep(for: .seconds(1))
                _ = try await engine.webView.evaluateJavaScript("video.requestFullscreen().catch(e=>window.fullscreenError=String(e));true")
                try await until("HTML video fullscreen") {
                    (try? await engine.webView.evaluateJavaScript("document.fullscreenElement===video")) as? Bool == true
                }
                try await Task.sleep(for: .seconds(1))
            }
            let focusedWindowNumber = NSApp.keyWindow?.windowNumber
            let before = try await snapshot(engine)
            _ = try await engine.webView.evaluateJavaScript("probe.reset();true")
            let start = ProcessInfo.processInfo.systemUptime
            child?.terminate()
            if let previous = child { try await until("old controller exit") { !previous.isRunning } }
            let next = Process()
            next.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            next.arguments = [repo.appendingPathComponent("experiments/controller-handoff/controller.py").path, home.path, String(generation)]
            next.standardOutput = FileHandle.nullDevice
            next.standardError = FileHandle.standardError
            try next.run()
            child = next
            controllerPIDs.insert(next.processIdentifier)
            try await until("controller \(generation) acknowledgement") {
                FileManager.default.fileExists(atPath: home.appendingPathComponent("ready-\(generation).json").path)
            }
            let handoffMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try await Task.sleep(for: .seconds(1))
            let after = try await snapshot(engine)
            require(next.isRunning, "Controller exited")
            require(after["token"] as? String == token, "Page identity changed")
            require(after["generation"] as? Int == generation, "Controller command not applied")
            require(after["paused"] as? Bool == false, "Video paused")
            require((after["time"] as? Double ?? 0) > (before["time"] as? Double ?? 0), "Video timeline stopped")
            require((after["ticks"] as? Int ?? 0) > (before["ticks"] as? Int ?? 0), "JS closure stopped")
            require((after["frames"] as? Int ?? 0) > 0, "No presented frames")
            require(after["interruptions"] as? Int == 0, "Media interruption event")
            require(window.windowNumber == windowNumber, "Window identity changed")
            require(ObjectIdentifier(engine.webView) == viewIdentity, "WKWebView replaced")
            if generation <= 6 {
                require(window.styleMask.contains(.fullScreen), "Native fullscreen exited")
                require(window.isKeyWindow, "Window lost focus")
            } else {
                require(after["htmlFullscreen"] as? Bool == true, "HTML fullscreen exited")
                require(NSApp.keyWindow?.windowNumber == focusedWindowNumber && NSApp.isActive, "Fullscreen presentation lost focus")
            }
            require(after["samePlayer"] as? Bool == true, "Video element replaced")
            if generation > 1 {
                require(handoffMS < 1000, "Controller handoff exceeded one second")
                require((after["maxGapMS"] as? Double ?? .infinity) < 250, "Frame callback gap exceeded 250ms")
                require((after["frames"] as? Int ?? 0) > 15, "Video frame delivery throttled")
            }
            samples.append(["mode": generation <= 6 ? "nativeFullscreen" : "htmlVideoFullscreen", "generation": generation, "controllerPID": next.processIdentifier,
                            "handoffMS": handoffMS, "before": before, "after": after])
        }
        require(controllerPIDs.count == 11, "Controller process was reused")
        let report: [String: Any] = ["passed": failures.isEmpty, "failures": failures, "hostPID": hostPID, "windowNumber": windowNumber, "samples": samples,
            "scope": "Production EngineView/BrainBridge; disposable controllers; local muted video; native and HTML video fullscreen. Does not replace native host, upgrade full BEAM backend, or verify audio output."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: home.appendingPathComponent("result.json"), options: .atomic)
        print("HANDOFF_REPORT \(home.appendingPathComponent("result.json").path)")
        _ = try await engine.webView.evaluateJavaScript("document.exitFullscreen();true")
        try await until("exit HTML fullscreen") {
            (try? await engine.webView.evaluateJavaScript("document.fullscreenElement===null")) as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    @MainActor private func snapshot(_ engine: EngineView) async throws -> [String: Any] {
        let value = try await engine.webView.evaluateJavaScript("probe.snapshot()")
        guard let data = value as? [String: Any] else { throw NSError(domain: "BadSnapshot", code: 1) }
        return data
    }

    @MainActor private func until(_ label: String, condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ControllerHandoffExperiment", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    private static let html = """
    <!doctype html><meta charset="utf-8"><style>
    body{margin:0;background:#101827;color:white;font:20px system-ui}video{width:100%;max-height:80vh}p{padding:0 24px}
    </style><video id="video" src="video.mp4" autoplay muted loop playsinline></video>
    <p id="generation">Waiting for controller</p><p>Isolated fixture — your browser session stays running.</p>
    <script>
    (()=>{
      const token=crypto.randomUUID(), secret=new Map([['ticks',0]]), originalVideo=video;
      let frames=0,maxGap=0,last=0,interruptions=0;
      setInterval(()=>secret.set('ticks',secret.get('ticks')+1),20);
      for(const name of ['pause','waiting','seeking','emptied','ended']) video.addEventListener(name,()=>interruptions++);
      function frame(now){frames++;if(last)maxGap=Math.max(maxGap,now-last);last=now;video.requestVideoFrameCallback(frame);}
      video.requestVideoFrameCallback(frame);
      window.probe={token,reset(){frames=0;maxGap=0;last=performance.now();interruptions=0;},
        snapshot(){return {token,samePlayer:video===originalVideo,htmlFullscreen:document.fullscreenElement===video,ticks:secret.get('ticks'),time:video.currentTime,paused:video.paused,
          frames,maxGapMS:maxGap,interruptions,generation:window.controllerGeneration||0};}};
    })();
    </script>
    """
}


// Compile these same production sources into a disposable app with its own entry point.
extension Bundle { static var module: Bundle { .main } }
@MainActor final class ExperimentDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await ControllerHandoffExperiment().testControllerReplacementPreservesLiveVideo() }
            catch {
                let text = "Experiment failed: \(error)"
                try? text.write(to: BowserPaths.home.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }
}
setenv("BOWSER_HOME", Bundle.main.object(forInfoDictionaryKey: "BowserExperimentHome") as! String, 1)
let app = NSApplication.shared
let delegate = ExperimentDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
