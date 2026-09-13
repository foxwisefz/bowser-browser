import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Bowser

@MainActor private final class ControllerPeer {
    let process = Process()
    let input = Pipe(), output = Pipe()
    init(root: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["elixir", root + "/tests/native-resources/controller.exs", root]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = try read()
    }
    func read() throws -> [String: Any] {
        var data = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
            data.append(byte)
        }
        throw CocoaError(.fileReadUnknown)
    }
    func call(_ value: [String: Any]) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        return try read()
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
}

@MainActor final class NativeControllerIntegrationTests: XCTestCase {
    func testActualElixirReplacementAndReconnectRetainPageDraftAndPendingIntent() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["BOWSER_RESOURCE_FIXTURE"],
              let root = ProcessInfo.processInfo.environment["BOWSER_TEST_ROOT"] else { throw XCTSkip("Run bin/check-resource-controller") }
        var peer = try ControllerPeer(root: root)
        defer { peer.stop() }
        let host = BrowserWindowController(profile: .defaultProfile)
        let first = host.activeTab!
        let second = host.openTab(activate: false), third = host.openTab(activate: false)
        let service = BrainBridge.shared.resources
        var events: [[String: Any]] = []
        service.emit = { events.append($0) }
        defer { service.enabled = false; service.emit = { BrainBridge.shared.send($0) }; host.window?.close() }
        let web = first.webView
        let url = URL(fileURLWithPath: fixture)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        host.window?.makeKeyAndOrderFront(nil)
        let surface = "controller-proof"
        let node: [String: Any] = ["t":"state", "key":"note", "values":["body":""], "content":["t":"editor", "field":"body"]]
        let sidebar = NSHostingView(rootView: SurfaceTreeView(surfaceId: surface, node: node))
        sidebar.frame = NSRect(x: 800, y: 0, width: 300, height: 600)
        host.window?.contentView?.addSubview(sidebar)
        defer { SurfaceFormStore.shared.remove(surface: surface) }
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!window.probe")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript("video.play(); true")
        let model = SurfaceFormStore.shared.model(surface: surface, key: "note", initial: [:])
        let editor = try XCTUnwrap(model.editor("body").textView)
        editor.insertText("unsaved 🐝", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        let undo = editor.undoManager
        host.window?.makeFirstResponder(editor)
        let before = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        service.ready()
        XCTAssertEqual(try peer.call(["reload":true])["reloaded"] as? Bool, true)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(host.moveTab(id: third.webviewId, relativeTo: second.webviewId, after: true))
        let intent = try XCTUnwrap(events.last(where: { $0["event"] as? String == "resource_intent" }))
        service.decide(try peer.call(intent))
        let roundTripMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(host.tabs.map(\.webviewId), [first.webviewId, third.webviewId, second.webviewId], "new Elixir policy must execute")
        XCTAssertTrue(host.activeTab === first)
        peer.stop()
        host.closeTab(id: second.webviewId) // remains queued while coordinator is gone
        XCTAssertEqual(host.tabs.count, 3)
        let queued = try XCTUnwrap(events.last(where: { $0["event"] as? String == "resource_intent" }))
        peer = try ControllerPeer(root: root)
        service.ready()
        let replay = try XCTUnwrap(events.last(where: { $0["event"] as? String == "resource_intent" }))
        XCTAssertEqual(replay["request"] as? String, queued["request"] as? String)
        let decision = try peer.call(replay)
        service.decide(decision); service.decide(decision)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertTrue(host.activeTab === first)
        XCTAssertTrue(first.webView === web)
        XCTAssertTrue(model.editor("body").textView === editor)
        XCTAssertEqual(editor.string, "unsaved 🐝")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertTrue(editor.undoManager === undo)
        XCTAssertTrue(host.window?.firstResponder === editor)
        if let value = ProcessInfo.processInfo.environment["BOWSER_DOWNLOAD_URL"], let downloadURL = URL(string: value) {
            let downloads = NativeDownloads.shared
            downloads.destinationDirectory = url.deletingLastPathComponent()
            defer { downloads.destinationDirectory = nil }
            let download: WKDownload = await withCheckedContinuation { continuation in
                third.webView.startDownload(using: URLRequest(url: downloadURL)) { continuation.resume(returning: $0) }
            }
            downloads.attach(download, tab: third.webviewId, profile: "default")
            for _ in 0..<100 {
                if downloads.snapshot.contains(where: { $0["awaiting_destination"] as? Bool == true }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let downloadIntent = try XCTUnwrap(events.last(where: { ($0["intent"] as? [String: Any])?["action"] as? String == "download_destination" }))
            service.decide(try peer.call(downloadIntent))
            peer.stop()
            host.closeTab(id: third.webviewId)
            peer = try ControllerPeer(root: root)
            service.ready()
            let close = try XCTUnwrap(events.last(where: { $0["event"] as? String == "resource_intent" }))
            service.decide(try peer.call(close))
            XCTAssertEqual(host.tabs.count, 1)
            for _ in 0..<300 {
                if downloads.snapshot.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(downloads.snapshot.isEmpty)
            let file = url.deletingLastPathComponent().appendingPathComponent("resource-download.bin")
            XCTAssertEqual(try Data(contentsOf: file).count, 1024 * 1024)
            print("RESOURCE_DOWNLOAD_PROOF completed 1MiB after source tab close and controller restart")
        }
        try await Task.sleep(for: .milliseconds(250))
        let after = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        XCTAssertEqual(before["token"] as? String, after["token"] as? String)
        XCTAssertEqual(after["paused"] as? Bool, false)
        XCTAssertGreaterThan(after["time"] as? Double ?? 0, before["time"] as? Double ?? 0)
        print("RESOURCE_CONTROLLER_PROOF \(roundTripMS)ms round trip; same webview/document/editor, queued close once, advancing video")
    }
}
