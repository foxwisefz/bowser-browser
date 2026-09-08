import AppKit
import WebKit

@MainActor final class BackendHandoffExperiment {
    func run() async throws {
        let home=BowserPaths.home
        guard home.path.hasPrefix("/tmp/bowser-handoff.") || home.path.hasPrefix("/private/tmp/bowser-handoff.") else { throw failure("Non-fixture home") }
        let repo=URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "BowserExperimentRepo") as! String)
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let profile=Profile(id:"handoff-work",name:"Fixture Work",tint:nil,icon:nil,uuid:nil)
        let engine=EngineView(frame:NSRect(x:0,y:0,width:1000,height:700),configuration:config,profile:profile)
        let secondaryConfig=WKWebViewConfiguration();secondaryConfig.websiteDataStore = .nonPersistent()
        let secondary=EngineView(frame:.zero,configuration:secondaryConfig,profile:Profile(id:"handoff-personal",name:"Fixture Personal",tint:nil,icon:nil,uuid:nil))
        secondary.webView.loadHTMLString("<title>Other profile fixture</title>",baseURL:URL(string:"https://profile-fixture.invalid"))
        let window=NSWindow(contentRect:engine.bounds,styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.collectionBehavior=[.fullScreenPrimary]
        window.title="Bowser — full backend handoff experiment"
        window.contentView=engine;engine.autoresizingMask=[.width,.height]
        window.makeKeyAndOrderFront(nil);NSApp.activate()
        let urlString=Bundle.main.object(forInfoDictionaryKey:"BowserExperimentURL") as? String ?? ""
        if urlString.isEmpty {
            let page=home.appendingPathComponent("fixture.html")
            try Self.html.write(to:page,atomically:true,encoding:.utf8)
            engine.load(urlString:page.absoluteString)
        } else { engine.load(urlString:urlString) }
        BrainBridge.shared.start()
        var relay:Process?
        defer {
            if relay?.isRunning == true { relay?.terminate() }
            engine.tearDown();secondary.tearDown();window.close()
        }
        try await until("video metadata",seconds:90) {
            (try? await engine.webView.evaluateJavaScript("!!document.querySelector('video') && document.querySelector('video').readyState>=1")) as? Bool == true
        }
        _ = try await engine.webView.evaluateJavaScript(Self.probe)
        _ = try await engine.webView.evaluateJavaScript("probe.player.muted=true;probe.player.play().catch(e=>window.playFailure=String(e));true")
        try await until("video playing") {
            (try? await engine.webView.evaluateJavaScript("!probe.player.paused && probe.player.currentTime>0.2")) as? Bool == true
        }
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        let driver = Bundle.main.object(forInfoDictionaryKey:"BowserExperimentDriver") as? String ?? "experiments/backend-handoff/relay.py"
        process.arguments=[repo.appendingPathComponent(driver).path,home.path,repo.path]
        let log=home.appendingPathComponent("relay.log");FileManager.default.createFile(atPath:log.path,contents:nil)
        process.standardOutput=try FileHandle(forWritingTo:log);process.standardError=process.standardOutput
        try process.run();relay=process
        try await until("initial full backend adoption",seconds:30) { FileManager.default.fileExists(atPath:home.appendingPathComponent("initial-ready").path) }
        BrainBridge.shared.send(["op":"event","event":"tab_activated","webview":engine.webviewId])
        _ = try await engine.webView.evaluateJavaScript("probe.player.requestFullscreen().catch(e=>window.fullscreenFailure=String(e));true")
        try await until("HTML fullscreen") {
            (try? await engine.webView.evaluateJavaScript("document.fullscreenElement===probe.player")) as? Bool == true
        }
        try await Task.sleep(for:.seconds(1))
        let windowNumber=window.windowNumber, identity=ObjectIdentifier(engine.webView), keyWindow=NSApp.keyWindow?.windowNumber
        _ = try await engine.webView.evaluateJavaScript("probe.start();true")
        let before=try await snapshot(engine)
        try Data().write(to:home.appendingPathComponent("run-backend-test"))
        var stopped=false
        try await until("backend replacement and rollback",seconds:45) {
            if FileManager.default.fileExists(atPath:home.appendingPathComponent("backend-failure.txt").path) { throw self.failure(try String(contentsOf:home.appendingPathComponent("backend-failure.txt"),encoding:.utf8)) }
            if !stopped && FileManager.default.fileExists(atPath:home.appendingPathComponent("stop-probes").path) {
                _ = try await engine.webView.evaluateJavaScript("probe.stop();true")
                try Data().write(to:home.appendingPathComponent("probes-stopped"));stopped=true
            }
            return FileManager.default.fileExists(atPath:home.appendingPathComponent("backend-result.json").path)
        }
        let after=try await snapshot(engine)
        var failures:[String]=[]
        func check(_ ok:Bool,_ message:String) { if !ok { failures.append(message) } }
        check(before["token"] as? String == after["token"] as? String,"Page changed")
        check(before["url"] as? String == after["url"] as? String,"Navigation occurred")
        check(after["samePlayer"] as? Bool == true,"Player replaced")
        check(after["htmlFullscreen"] as? Bool == true,"HTML fullscreen exited")
        check(after["paused"] as? Bool == false,"Playback paused")
        check((after["time"] as? Double ?? 0) > (before["time"] as? Double ?? 0),"Playback did not advance")
        check((after["ticks"] as? Int ?? 0) > (before["ticks"] as? Int ?? 0),"JS closure stopped")
        check(after["interruptions"] as? Int == 0,"Media interruption event")
        check((after["maxGapMS"] as? Double ?? .infinity)<250,"Video frame callback gap exceeded 250ms")
        check(window.windowNumber==windowNumber && ObjectIdentifier(engine.webView)==identity,"Native identity changed")
        check(NSApp.keyWindow?.windowNumber==keyWindow && NSApp.isActive,"Fullscreen focus changed")
        check(before["scrollY"] as? Double == after["scrollY"] as? Double,"Page scroll changed")
        let backend=try JSONSerialization.jsonObject(with:Data(contentsOf:home.appendingPathComponent("backend-result.json"))) as! [String:Any]
        check(after["sequence"] as? Int == backend["probesCaptured"] as? Int,"Generated host events were lost before journal capture")
        let result:[String:Any]=["passed":failures.isEmpty,"failures":failures,"hostPID":ProcessInfo.processInfo.processIdentifier,
            "before":before,"after":after,"backend":backend,"source":urlString.isEmpty ? "local fixture" : urlString,
            "scope":driver == "experiments/installed-handoff/drive.py" ? "Installed updater/relay, actual release and stateful mod; muted media; disposable native host." : "Full production BEAM supervision tree; prototype stable relay; muted media; not installed updater."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:home.appendingPathComponent("result.json"))
        _ = try await engine.webView.evaluateJavaScript("document.exitFullscreen();true")
        try await Task.sleep(for:.seconds(1))
    }
    func failure(_ message:String)->NSError { NSError(domain:"BackendHandoff",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    func snapshot(_ engine:EngineView) async throws -> [String:Any] {
        guard let result=try await engine.webView.evaluateJavaScript("probe.snapshot()") as? [String:Any] else { throw failure("No probe snapshot") };return result
    }
    func until(_ label:String,seconds:Double=15,condition:() async throws -> Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<deadline {
            if try await condition(){return};try await Task.sleep(for:.milliseconds(20))
        };throw failure("Timed out: "+label)
    }
    static let probe="""
    (()=>{
      const player=document.querySelector('video'),token=crypto.randomUUID(),state=new Map([['ticks',0]]);
      let frames=0,last=0,maxGap=0,interruptions=0,sequence=0,enabled=false;
      setInterval(()=>{state.set('ticks',state.get('ticks')+1);if(enabled)window.bowser.emit({kind:'handoff_probe',sequence:++sequence});},20);
      for(const event of ['pause','waiting','seeking','emptied','ended'])player.addEventListener(event,()=>interruptions++);
      function frame(now){frames++;if(last)maxGap=Math.max(maxGap,now-last);last=now;player.requestVideoFrameCallback(frame);}
      player.requestVideoFrameCallback(frame);
      window.probe={player,start(){frames=0;last=performance.now();maxGap=0;interruptions=0;enabled=true;},stop(){enabled=false;},
        snapshot(){return {token,url:location.href,samePlayer:document.querySelector('video')===player,time:player.currentTime,
          paused:player.paused,htmlFullscreen:document.fullscreenElement===player,frames,maxGapMS:maxGap,interruptions,
          ticks:state.get('ticks'),sequence,scrollY:window.scrollY,generation:window.controllerGeneration||0};}};
      return true;
    })();
    """
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
extension Bundle { static var module:Bundle { .main } }
@MainActor final class ExperimentDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        Task { @MainActor in
            do { try await BackendHandoffExperiment().run() }
            catch { try? String(describing:error).write(to:BowserPaths.home.appendingPathComponent("failure.txt"),atomically:true,encoding:.utf8) }
            NSApp.terminate(nil)
        }
    }
}
setenv("BOWSER_HOME",Bundle.main.object(forInfoDictionaryKey:"BowserExperimentHome") as! String,1)
let app=NSApplication.shared
let delegate=ExperimentDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
