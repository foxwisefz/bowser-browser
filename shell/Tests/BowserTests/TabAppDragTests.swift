import AppKit
import XCTest
import IconRendering
@testable import Bowser

final class TabAppDragTests: XCTestCase {
    @MainActor func testOptionDragClosesWithoutPublishingPasteboardAndEscapeCancels() throws {
        SurfaceHostServices.configure()
        let host = BrowserWindowController(profile: .defaultProfile)
        let target = host.openTab(activate: false)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 100, width: 48, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = TabAppDragView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        panel.contentView = view
        defer { panel.close(); host.window?.close() }
        view.webviewID = target.webviewId
        let pasteboard = NSPasteboard(name: .drag)
        let changeCount = pasteboard.changeCount
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 16),
                modifierFlags: .option, timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, x: 16))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 180))
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        view.cancelOperation(nil)
        view.mouseUp(with: try event(.leftMouseUp, x: 180))
        XCTAssertTrue(host.tabs.contains { $0 === target })
        view.mouseDown(with: try event(.leftMouseDown, x: 16))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 180))
        view.mouseUp(with: try event(.leftMouseUp, x: 180))
        XCTAssertFalse(host.tabs.contains { $0 === target })
        XCTAssertEqual(pasteboard.changeCount, changeCount)
    }

    @MainActor func testMouseGestureDefersReplacementUntilReleaseAndRejectsRetiredInput() throws {
        let view = TabAppDragView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let slot = NativeModuleSlot(fallback: NSView(), kind: .surfaces)
        slot.setSnapshot(Data("{}".utf8))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var selections = 0
        view.select = { selections += 1 }
        view.mouseDown(with: event)
        XCTAssertTrue(SurfaceServices.shared.hasInteractions)
        XCTAssertFalse(slot.canReplace)
        view.mouseUp(with: event)
        XCTAssertFalse(SurfaceServices.shared.hasInteractions)
        XCTAssertEqual(selections, 1)
        view.isAuthorized = { false }
        view.mouseDown(with: event); view.mouseUp(with: event)
        XCTAssertFalse(SurfaceServices.shared.hasInteractions)
        XCTAssertEqual(selections, 1)
    }

    @MainActor func testInsertionPreviewReservesOneFullSlotAndClearsOnlyItsTarget() {
        let preview = TabDragPreview()
        preview.source = 1
        preview.target = 3
        preview.after = false
        XCTAssertEqual(preview.gap(for: 3, after: false, size: 40), 40)
        XCTAssertEqual(preview.gap(for: 3, after: true, size: 40), 0)
        preview.clear(target: 2)
        XCTAssertEqual(preview.target, 3)
        preview.finish()
        XCTAssertNil(preview.source)
        XCTAssertEqual(preview.gap(for: 3, after: false, size: 40), 0)
    }

    @MainActor func testDragOutRequiresUnacceptedMouseReleaseFarFromDock() {
        let dock = NSRect(x: 0, y: 20, width: 48, height: 900)
        let outside = NSPoint(x: 220, y: 450)
        func removes(_ operation: NSDragOperation = [], cancelled: Bool = false, buttons: Int = 0,
                     failed: Bool = false, point: NSPoint? = nil, closing: Bool = true) -> Bool {
            TabAppDragView.shouldRemove(closing: closing, operation: operation, cancelled: cancelled, mouseButtons: buttons,
                exportFailed: failed, point: point ?? outside, dock: dock)
        }
        XCTAssertTrue(removes())
        XCTAssertFalse(removes(closing: false))
        for accepted: NSDragOperation in [.move, .copy, .link, .generic] { XCTAssertFalse(removes(accepted)) }
        XCTAssertFalse(removes(cancelled: true))
        XCTAssertFalse(removes(buttons: 1))
        XCTAssertFalse(removes(failed: true))
        XCTAssertFalse(removes(point: NSPoint(x: 75, y: 450)))
        XCTAssertFalse(removes(point: NSPoint(x: 24, y: 450)))
        XCTAssertFalse(TabAppDragView.shouldRemove(closing: true, operation: [], cancelled: false, mouseButtons: 0,
            exportFailed: false, point: outside, dock: nil))
    }

    @MainActor func testDustRespectsReducedMotion() {
        for reduced in [false, true] {
            let layer = CALayer()
            TabDustEffect.populate(layer, size: NSSize(width: 180, height: 160), reducedMotion: reduced, duration: 0.5)
            XCTAssertEqual(layer.sublayers?.count, 24)
            let animation = layer.sublayers?.first?.animation(forKey: "dust") as? CAAnimationGroup
            let keys = animation?.animations?.compactMap { ($0 as? CAPropertyAnimation)?.keyPath }
            XCTAssertEqual(keys?.contains("position"), !reduced)
            XCTAssertEqual(keys?.contains("opacity"), true)
        }
    }

    @MainActor func testSavedAppIsGeneratedOnlyWhenFileRepresentationIsRequested() {
        var creations = 0
        let url = URL(fileURLWithPath: "/tmp/test-saved-app.app")
        let provider = TabAppPasteboardProvider { creations += 1; return url }
        let item = NSPasteboardItem()
        item.setString("42", forType: TabAppDragView.tabType)
        item.setDataProvider(provider, forTypes: [.fileURL])
        XCTAssertEqual(item.string(forType: TabAppDragView.tabType), "42")
        XCTAssertEqual(creations, 0)
        provider.pasteboard(nil, item: item, provideDataForType: .fileURL)
        XCTAssertEqual(item.string(forType: .fileURL), url.absoluteString)
        provider.pasteboard(nil, item: item, provideDataForType: .fileURL)
        XCTAssertEqual(creations, 1)
    }

    @MainActor
    func testCreatesReusableApplicationWithSafeLauncherAndIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = URL(string: "https://example.com/dashboard?q=hello&value=$(touch%20bad)")!
        let browser = root.appendingPathComponent("Bowser's App.app")
        let source = browser.appendingPathComponent("Contents/MacOS/Bowser")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: source)
        let kit = browser.appendingPathComponent("Contents/Frameworks/libBowserSurfaceKit.dylib")
        try FileManager.default.createDirectory(at: kit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("state library".utf8).write(to: kit)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        let start = ProcessInfo.processInfo.systemUptime
        let bundle = try TabAppBundle.create(url: page, profile: "work", iconData: IconRenderer.icns(icon.tiffRepresentation!), directory: root, bowser: browser, sign: false)
        print("Tab app preparation: \((ProcessInfo.processInfo.systemUptime - start) * 1000)ms")
        XCTAssertEqual(bundle.pathExtension, "app")
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("Contents/Frameworks/libBowserSurfaceKit.dylib")), try Data(contentsOf: kit))
        let app = try XCTUnwrap(Bundle(url: bundle))
        XCTAssertEqual(app.infoDictionary?["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(app.infoDictionary?["BowserSavedURL"] as? String, page.absoluteString)
        XCTAssertEqual(app.infoDictionary?["BowserProfile"] as? String, "work")
        let executable = try XCTUnwrap(app.executableURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertEqual(try Data(contentsOf: executable), try Data(contentsOf: source))
        XCTAssertEqual(SiteAppConfiguration.parse(app.infoDictionary ?? [:])?.url, page)
        XCTAssertNotNil(NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/SiteIcon.icns")))
        let again = try TabAppBundle.create(url: page, profile: "work", iconData: nil, directory: root, bowser: browser, sign: false)
        XCTAssertEqual(bundle, again)
        // An already-pinned v1 launcher is upgraded at exactly the same path.
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        var oldInfo = app.infoDictionary!
        oldInfo.removeValue(forKey: "BowserAppVersion")
        try PropertyListSerialization.data(fromPropertyList: oldInfo, format: .xml, options: 0).write(to: plist)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try TabAppBundle.upgrade(bundle: bundle, bowser: browser, sign: false)
        XCTAssertEqual(try Data(contentsOf: executable), try Data(contentsOf: source))
        let updated = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        XCTAssertEqual(updated["BowserAppVersion"] as? Int, 2)
        let other = try TabAppBundle.create(url: page, profile: "personal", iconData: nil, directory: root, bowser: browser, sign: false)
        XCTAssertNotEqual(bundle, other)
    }

    @MainActor
    func testRejectsNonWebLaunchTargets() {
        XCTAssertThrowsError(try TabAppBundle.create(url: URL(string: "file:///tmp/test")!, profile: "default", iconData: nil,
                                                    directory: FileManager.default.temporaryDirectory,
                                                    bowser: URL(fileURLWithPath: "/Applications/Bowser.app")))
    }
}
