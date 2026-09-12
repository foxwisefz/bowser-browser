import BowserSurfaceKit
import AppKit
import CryptoKit
import SwiftUI

/// Persistent site apps reuse Bowser’s executable, with their own macOS identity.
@MainActor
enum TabAppBundle {
    static func create(url: URL, profile: String, iconData: Data?, directory: URL,
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
        try copyStateLibrary(from: bowser, to: staging)
        let info: [String: Any] = [
            "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleIdentifier": "com.foxwiseai.bowser.site.\(key)",
            "CFBundleExecutable": "launch", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "2", "BowserAppVersion": 2,
            "BowserEngineBuild": try engineBuild(bowser),
            "BowserMainApp": bowser.path, "CFBundleIconFile": "SiteIcon.icns",
            "BowserSavedURL": url.absoluteString, "BowserProfile": profile,
        ]
        if let iconData {
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try iconData.write(to: resources.appendingPathComponent("SiteIcon.icns"))
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
              identifier.hasPrefix("com.foxwiseai.bowser.site."), info["BowserSavedURL"] is String else { return }
        let build = try engineBuild(bowser)
        let engineChanged = info["BowserAppVersion"] as? Int != 2 || info["BowserEngineBuild"] as? String != build
        let savedURL = (info["BowserSavedURL"] as? String).flatMap(URL.init(string:))
        let cached = savedURL.flatMap { cachedIcon(url: $0, profile: info["BowserProfile"] as? String ?? "default") }
        let iconHash = cached.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let iconChanged = iconHash != nil && info["BowserIconHash"] as? String != iconHash
        guard engineChanged || iconChanged else { return }
        // Updating an executing Mach-O can kill its process. Leave running
        // apps alone; they will be upgraded after they have quit.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { !$0.isTerminated }) else { return }
        if engineChanged {
            let target = bundle.appendingPathComponent("Contents/MacOS/launch")
            let temp = target.appendingPathExtension("new")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: bowser.appendingPathComponent("Contents/MacOS/Bowser"), to: temp)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            try copyStateLibrary(from: bowser, to: bundle)
            info["BowserAppVersion"] = 2
            info["CFBundleVersion"] = "2"
            info["BowserEngineBuild"] = build
            info["BowserMainApp"] = bowser.path
        }
        if iconChanged, let cached {
            let resources = bundle.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try cached.write(to: resources.appendingPathComponent("SiteIcon.icns"), options: .atomic)
            info["BowserIconHash"] = iconHash
        }
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

    private static func copyStateLibrary(from browser: URL, to bundle: URL) throws {
        let relative = "Contents/Frameworks/libBowserSurfaceKit.dylib"
        let destination = bundle.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.copyItem(at: browser.appendingPathComponent(relative), to: temp)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: destination) }
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

    nonisolated static func iconKey(url: URL, profile: String) -> String {
        let origin = "\(url.scheme ?? "https")://\(url.host ?? "")" + (url.port.map { ":\($0)" } ?? "")
        return SHA256.hash(data: Data((profile + "\n" + origin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func cachedIcon(url: URL, profile: String) -> Data? {
        try? Data(contentsOf: BowserPaths.home.appendingPathComponent("app-icons-v2/" + iconKey(url: url, profile: profile) + ".icns"))
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

/// File export is lazy: moving within Bowser must not build/sign a saved app.
final class TabAppPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    var makeBundle: () throws -> URL
    private var bundle: URL?
    private(set) var failed = false
    init(makeBundle: @escaping () throws -> URL) { self.makeBundle = makeBundle }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL else { return }
        do {
            if bundle == nil { bundle = try makeBundle() }
            item.setString(bundle!.absoluteString, forType: .fileURL)
        } catch { failed = true; NSLog("Bowser: tab app drag failed: %@", error.localizedDescription) }
    }
}

final class TabAppDragView: NSView, NSDraggingSource {
    static let tabType = NSPasteboard.PasteboardType("com.foxwiseai.bowser.tab")
    var webviewID: UInt64 = 0
    var select: () -> Void = {}
    private var down: NSEvent?
    private var dragged = false
    private(set) var draggedID: UInt64?
    private var provider: TabAppPasteboardProvider?
    private var insertionAfter: Bool?
    private var dragFrame: NSRect?
    private var cancelled = false
    private var closeGesture = false
    private var closeCue: NSPanel?
    private var closeIcon: NSImage?
    private var escapeMonitor: Any?

    /// A failed/cancelled drag is not automatically a request to close a tab.
    static func shouldRemove(closing: Bool, operation: NSDragOperation, cancelled: Bool, mouseButtons: Int,
                             exportFailed: Bool, point: NSPoint, dock: NSRect?) -> Bool {
        guard closing, operation.isEmpty, !cancelled, mouseButtons & 1 == 0, !exportFailed,
              let dock else { return false }
        return !dock.insetBy(dx: -64, dy: -32).contains(point)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.tabType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = event; dragged = false }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        if dragged && closeGesture {
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            let remove = Self.shouldRemove(closing: true, operation: [], cancelled: cancelled,
                mouseButtons: 0, exportFailed: false, point: point, dock: dragFrame)
            let id = draggedID
            finishDrag()
            if remove, let id, let host = BrowserWindowController.host(of: id) {
                TabDustEffect.show(at: point)
                host.closeTab(id: id)
            }
        } else if !dragged, down != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { select() }
    }
    override func mouseDragged(with event: NSEvent) {
        if dragged && closeGesture {
            updateCloseCue(at: window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
            return
        }
        guard !dragged, let down,
              hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 5,
              let tab = EngineView.live[webviewID] else { return }
        dragged = true
        draggedID = webviewID
        TabDragPreview.shared.source = webviewID
        dragFrame = window?.frame
        cancelled = false
        closeGesture = event.modifierFlags.contains(.option)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelOperation(nil) }
            return event
        }
        let icon = tab.faviconPath.flatMap { NSImage(contentsOfFile: $0) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        if closeGesture {
            closeIcon = icon
            // Keep this entirely in AppKit mouse tracking: no drag pasteboard,
            // file promise, URL or drop operation is offered to another app.
            SurfaceManager.shared.setEdgeDragging("edge_dock", true)
            updateCloseCue(at: window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
            return
        }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(String(webviewID), forType: Self.tabType)
        if let url = tab.webView.url, ["http", "https"].contains(url.scheme ?? "") {
            let profile = tab.profileId, iconData = tab.appIconData
            let provider = TabAppPasteboardProvider {
                let bowser = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL
                    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser.app")
                return try TabAppBundle.create(url: url, profile: profile, iconData: iconData,
                                               directory: TabAppBundle.directory, bowser: bowser)
            }
            self.provider = provider
            pasteboard.setDataProvider(provider, forTypes: [.fileURL])
        }
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        item.setDraggingFrame(bounds, contents: icon)
        SurfaceManager.shared.setEdgeDragging("edge_dock", true)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move] : [.copy, .link, .generic]
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }

    override func cancelOperation(_ sender: Any?) {
        cancelled = true
        closeCue?.orderOut(nil)
    }

    private func finishDrag() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        closeCue?.close()
        closeCue = nil
        closeIcon = nil
        down = nil
        draggedID = nil
        closeGesture = false
        TabDragPreview.shared.finish()
        provider = nil
        dragFrame = nil
        SurfaceManager.shared.setEdgeDragging("edge_dock", false)
    }

    private func updateCloseCue(at point: NSPoint) {
        guard !cancelled else { return }
        let ready = Self.shouldRemove(closing: true, operation: [], cancelled: false,
            mouseButtons: 0, exportFailed: false, point: point, dock: dragFrame)
        let panel = closeCue ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 52),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if closeCue == nil {
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            closeCue = panel
        }
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 10) {
                if let closeIcon {
                    Image(nsImage: closeIcon).resizable().scaledToFit()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
                Text(ready ? "Release to close" : "Drag out to close")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)))
        panel.setFrameOrigin(NSPoint(x: point.x + 18, y: point.y - 62))
        panel.orderFrontRegardless()
    }

    private func sourceID(_ sender: NSDraggingInfo) -> UInt64? {
        guard let source = sender.draggingSource as? TabAppDragView,
              let id = source.draggedID, id != webviewID,
              let host = BrowserWindowController.host(of: id),
              host === BrowserWindowController.host(of: webviewID) else { return nil }
        return id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sourceID(sender) != nil else { clearInsertion(); return [] }
        // NSView's origin is bottom-left; the lower half inserts after this row.
        // Keep the chosen edge stable while its expanded drop gap is hovered.
        if insertionAfter == nil {
            insertionAfter = convert(sender.draggingLocation, from: nil).y < bounds.midY
            TabDragPreview.shared.after = insertionAfter == true
            TabDragPreview.shared.target = webviewID
        }
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearInsertion() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { sourceID(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearInsertion() }
        guard let id = sourceID(sender), let after = insertionAfter else { return false }
        return BrowserWindowController.host(of: id)?.moveTab(id: id, relativeTo: webviewID, after: after) == true
    }
    private func clearInsertion() {
        insertionAfter = nil
        TabDragPreview.shared.clear(target: webviewID)
    }
}
