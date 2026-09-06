import AppKit
import CryptoKit
import SwiftUI

/// Persistent site apps reuse Bowser’s executable, with their own macOS identity.
@MainActor
enum TabAppBundle {
    static func create(url: URL, profile: String, icon: NSImage?, directory: URL,
                       bowser: URL, sign: Bool = true) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host else { throw CocoaError(.fileWriteInvalidFileName) }
        let identity = Data((profile + "\n" + url.absoluteString).utf8)
        let key = SHA256.hash(data: identity).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = host.replacingOccurrences(of: "/", with: "_")
        let bundle = directory.appendingPathComponent("\(name)-\(key).app", isDirectory: true)
        // Stable paths are essential: the Dock keeps a reference to this file.
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) {
            try upgrade(bundle: bundle, bowser: bowser, sign: sign)
            return bundle
        }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).app")
        let contents = staging.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/launch")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: bowser.appendingPathComponent("Contents/MacOS/Bowser"), to: executable)
        let info: [String: Any] = [
            "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleIdentifier": "com.gezim.bowser.site.\(key)",
            "CFBundleExecutable": "launch", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "2", "BowserAppVersion": 2,
            "BowserEngineBuild": try engineBuild(bowser),
            "BowserMainApp": bowser.path, "CFBundleIconFile": "SiteIcon.icns",
            "BowserSavedURL": url.absoluteString, "BowserProfile": profile,
        ]
        if let icon {
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try iconData(icon).write(to: resources.appendingPathComponent("SiteIcon.icns"))
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if sign { try signBundle(staging) }
        try FileManager.default.moveItem(at: staging, to: bundle)
        return bundle
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser Apps")
    }

    static func engineBuild(_ bowser: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: bowser.appendingPathComponent("Contents/MacOS/Bowser").path)
        return "\(attrs[.size] ?? 0)-\(attrs[.modificationDate] ?? "")"
    }

    static func upgrade(bundle: URL, bowser: URL, sign: Bool = true) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier.hasPrefix("com.gezim.bowser.site."), info["BowserSavedURL"] is String else { return }
        let build = try engineBuild(bowser)
        guard info["BowserAppVersion"] as? Int != 2 || info["BowserEngineBuild"] as? String != build else { return }
        // Updating an executing Mach-O can kill its process. Leave running
        // apps alone; they will be upgraded after they have quit.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { !$0.isTerminated }) else { return }
        let target = bundle.appendingPathComponent("Contents/MacOS/launch")
        let temp = target.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.copyItem(at: bowser.appendingPathComponent("Contents/MacOS/Bowser"), to: temp)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        info["BowserAppVersion"] = 2
        info["CFBundleVersion"] = "2"
        info["BowserEngineBuild"] = build
        info["BowserMainApp"] = bowser.path
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist, options: .atomic)
        if sign { try signBundle(bundle) }
    }

    static func upgradeSavedApps() {
        guard SiteAppConfiguration.current == nil else { return }
        let bundles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for bundle in bundles where bundle.pathExtension == "app" {
            do { try upgrade(bundle: bundle, bowser: Bundle.main.bundleURL) }
            catch { NSLog("Bowser: site app upgrade failed: %@", error.localizedDescription) }
        }
    }

    private static func signBundle(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
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
