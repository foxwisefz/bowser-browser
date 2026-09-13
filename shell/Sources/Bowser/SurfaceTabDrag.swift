import AppKit
import SwiftUI
import BowserSurfaceKit

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

final class TabAppDragView: NSView, NSDraggingSource, SurfaceTabDragSource {
    var isAuthorized: () -> Bool = { true }
    private var interaction: UUID?
    private func beginInteraction() {
        if interaction == nil { interaction = SurfaceServices.shared.beginInteraction() }
    }
    private func endInteraction() {
        if let interaction { SurfaceServices.shared.endInteraction(interaction) }; interaction = nil
    }
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
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, interaction != nil { cancelled = true; finishDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard isAuthorized() else { return }; beginInteraction(); down = event; dragged = false
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil; endInteraction() }
        if dragged && closeGesture {
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            let remove = Self.shouldRemove(closing: true, operation: [], cancelled: cancelled,
                mouseButtons: 0, exportFailed: false, point: point, dock: dragFrame)
            let id = draggedID
            finishDrag()
            if remove, let id, SurfaceServices.shared.closeTab(id) {
                TabDustEffect.show(at: point)
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
              let tab = SurfaceServices.shared.tabSnapshot(webviewID) else { return }
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
        let icon = tab.icon
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        if closeGesture {
            closeIcon = icon
            // Keep this entirely in AppKit mouse tracking: no drag pasteboard,
            // file promise, URL or drop operation is offered to another app.
            SurfaceServices.shared.edgeDragging(true)
            updateCloseCue(at: window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
            return
        }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(String(webviewID), forType: Self.tabType)
        if tab.canExport {
            let id = webviewID
            let provider = TabAppPasteboardProvider { try SurfaceServices.shared.exportTab(id) }
            self.provider = provider
            pasteboard.setDataProvider(provider, forTypes: [.fileURL])
        }
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        item.setDraggingFrame(bounds, contents: icon)
        SurfaceServices.shared.edgeDragging(true)
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
        endInteraction()
        closeCue?.close()
        closeCue = nil
        closeIcon = nil
        down = nil
        draggedID = nil
        closeGesture = false
        TabDragPreview.shared.finish()
        provider = nil
        dragFrame = nil
        SurfaceServices.shared.edgeDragging(false)
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
        guard let source = sender.draggingSource as? any SurfaceTabDragSource,
              let id = source.draggedID, id != webviewID,
              isAuthorized(), SurfaceServices.shared.canMoveTab(id, webviewID) else { return nil }
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
        return SurfaceServices.shared.moveTab(id, webviewID, after)
    }
    private func clearInsertion() {
        insertionAfter = nil
        TabDragPreview.shared.clear(target: webviewID)
    }
}
