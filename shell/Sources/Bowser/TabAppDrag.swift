import AppKit
import CryptoKit
import SwiftUI

/// First-stage site app: a persistent Dock target that opens its saved URL
/// in Bowser. A separate app process/window is deliberately a later step.
@MainActor
enum TabAppBundle {
    static func create(url: URL, profile: String, icon: NSImage?, directory: URL,
                       bowser: URL) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host else { throw CocoaError(.fileWriteInvalidFileName) }
        let identity = Data((profile + "\n" + url.absoluteString).utf8)
        let key = SHA256.hash(data: identity).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = host.replacingOccurrences(of: "/", with: "_")
        let bundle = directory.appendingPathComponent("\(name)-\(key).app", isDirectory: true)
        // Stable paths are essential: the Dock keeps a reference to this file.
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) {
            return bundle
        }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).app")
        let contents = staging.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/launch")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let script = "#!/bin/sh\nexec /usr/bin/open -a \(shellQuote(bowser.path)) -- \(shellQuote(url.absoluteString))\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = [
            "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleIdentifier": "com.gezim.bowser.site.\(key)",
            "CFBundleExecutable": "launch", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleIconFile": "SiteIcon.icns",
            "BowserSavedURL": url.absoluteString, "BowserProfile": profile,
        ]
        if let icon {
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try iconData(icon).write(to: resources.appendingPathComponent("SiteIcon.icns"))
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.moveItem(at: staging, to: bundle)
        return bundle
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func iconData(_ image: NSImage) throws -> Data {
        // ICNS supports PNG payloads. Generate directly rather than spawning
        // iconutil or a compiler on the mouse event path.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        func size(_ n: Int) -> Data {
            var value = UInt32(n).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        return Data("icns".utf8) + size(png.count + 16) + Data("ic07".utf8) + size(png.count + 8) + png
    }
}

struct TabAppDragTarget: NSViewRepresentable {
    let webviewID: UInt64
    let select: () -> Void

    func makeNSView(context: Context) -> TabAppDragView { TabAppDragView() }
    func updateNSView(_ view: TabAppDragView, context: Context) {
        view.webviewID = webviewID
        view.select = select
    }
}

final class TabAppDragView: NSView, NSDraggingSource {
    var webviewID: UInt64 = 0
    var select: () -> Void = {}
    private var down: NSEvent?
    private var dragged = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = event; dragged = false }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        if !dragged, down != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { select() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let down,
              hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 5,
              let tab = EngineView.live[webviewID], let url = tab.webView.url else { return }
        dragged = true
        let start = ProcessInfo.processInfo.systemUptime
        let icon = tab.faviconPath.flatMap { NSImage(contentsOfFile: $0) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser Apps")
            let bowser = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser.app")
            let bundle = try TabAppBundle.create(url: url, profile: tab.profileId, icon: icon,
                                                 directory: directory, bowser: bowser)
            let item = NSDraggingItem(pasteboardWriter: bundle as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            let session = beginDraggingSession(with: [item], event: down, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            NSLog("Bowser: tab app drag prepared in %.1fms: %@", (ProcessInfo.processInfo.systemUptime - start) * 1000, bundle.path)
        } catch {
            NSLog("Bowser: tab app drag failed: %@", error.localizedDescription)
            NSSound.beep()
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        down = nil
        NSLog("Bowser: tab app drag ended operation=%lu", operation.rawValue)
    }
}
