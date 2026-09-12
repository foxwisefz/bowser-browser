import BowserSurfaceKit
import AppKit
import SwiftUI

/// ADR 0009: mods own surfaces — native windows whose content is a
/// declarative view tree sent as JSON from Elixir, rendered as SwiftUI.
/// Look: borderless translucent HUD panels (vibrancy material adapts to
/// light/dark automatically), rounded corners, hover rows, gradient accent
/// for active state. Drag anywhere to move.
@MainActor
final class SurfaceManager {
    static let shared = SurfaceManager()

    private var panels: [String: NSPanel] = [:]
    private var hostings: [String: NSHostingView<AnyView>] = [:]
    private var activationObserved = false
    private var scopedMessages: [String: [String: Any]] = [:]
    private var activeProfile = "default"

    private func belongsToActiveProfile(_ id: String) -> Bool {
        guard let profile = scopedMessages[id]?["profile"] as? String else { return true }
        return profile == activeProfile
    }

    /// Floating panels ride above the browser window only while Bowser is
    /// the active app; otherwise they drop to normal level and behave like
    /// ordinary windows of an inactive app (behind whatever is in front,
    /// still there when you come back). Edges/overlays are children of the
    /// main window and need nothing.
    private func observeActivation() {
        guard !activationObserved else { return }
        activationObserved = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setFloatingPanels(level: .normal) }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setFloatingPanels(level: .floating, front: true) }
        }
    }

    private func setFloatingPanels(level: NSWindow.Level, front: Bool = false) {
        // Independent floating panels only: a child window (toolbar overlay,
        // window-attached edge) ordered front raises its PARENT — on app
        // reactivation that shoved the overlay's original window on top.
        for (id, panel) in panels where edgeConfigs[id] == nil && panel.parent == nil {
            panel.level = level
            if front && belongsToActiveProfile(id) { panel.orderFront(nil) }
        }
    }

    func handle(_ message: [String: Any]) {
        SurfaceHostServices.configure()
        switch message["surface"] as? String {
        case "show":
            guard let id = message["id"] as? String,
                  let tree = message["view"] as? [String: Any] else { return }
            if message["profile"] is String {
                scopedMessages[id] = message
                guard belongsToActiveProfile(id) else {
                    panels[id]?.orderOut(nil)
                    SettingsWindow.shared.remove(id: id)
                    return
                }
            }
            if message["kind"] as? String == "settings" {
                // A section of the Settings window, not a panel. A floating
                // leftover with this id (from before it moved) goes away.
                if let panel = panels.removeValue(forKey: id) {
                    panel.parent?.removeChildWindow(panel)
                    panel.close()
                }
                hostings.removeValue(forKey: id)
                SettingsWindow.shared.set(
                    id: id,
                    title: message["title"] as? String ?? id,
                    order: message["order"] as? Int ?? 50,
                    tree: tree
                )
                if message["activate"] as? Bool == true {
                    SettingsWindow.shared.show(select: id)
                }
                return
            }
            if message["kind"] as? String == "toolbar_overlay" {
                showToolbarOverlay(id: id, tree: tree)
                return
            }
            if message["kind"] as? String == "edge" {
                showEdge(
                    id: id,
                    edge: message["edge"] as? String ?? "left",
                    peek: message["peek"] as? Double ?? 6,
                    width: message["width"] as? Double ?? 72,
                    attach: message["attach"] as? String ?? "window",
                    tree: tree
                )
                return
            }
            show(
                id: id,
                title: message["title"] as? String ?? id,
                anchor: message["anchor"] as? String ?? "right_of_main",
                width: message["width"] as? Double ?? 240,
                tree: tree
            )
        case "close":
            guard let id = message["id"] as? String else { return }
            scopedMessages.removeValue(forKey: id)
            SettingsWindow.shared.remove(id: id)
            SurfaceFormStore.shared.remove(surface: id)
            hostings.removeValue(forKey: id)
            overlayHostings.removeValue(forKey: id)
            if let panel = panels.removeValue(forKey: id) {
                panel.parent?.removeChildWindow(panel)
                panel.close()
            }
        default:
            NSLog("Bowser: unknown surface op")
        }
    }

    func dismiss(id: String) {
        handle(["surface": "close", "id": id])
        ChromeSurface.emit(["op": "event", "event": "surface_dismiss", "surface": id])
    }

    static func fittedHeight(surfaceId: String, title: String, node: [String: Any], width: CGFloat) -> CGFloat {
        let content = SurfaceRootView(surfaceId: surfaceId, title: title, node: node).panelContent
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
        return max(60, NSHostingView(rootView: content).fittingSize.height.rounded(.up))
    }

    // MARK: - Toolbar overlay: a click-through child window riding the main
    // window's toolbar region. Effects (particles etc.) render here, over
    // the real chrome.

    private var overlayHostings: [String: NSHostingView<AnyView>] = [:]
    private var overlayObserver: Any?

    private func showToolbarOverlay(id: String, tree: [String: Any]) {
        let root = AnyView(LiveSurfaceTree(surfaceId: id, node: tree))

        if let hosting = overlayHostings[id], let panel = panels[id] {
            hosting.rootView = root
            positionOverlay(panel)
            return
        }

        guard let main = NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.windowController is BrowserWindowController })
        else { return }

        let panel = SurfacePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        main.addChildWindow(panel, ordered: .above)
        positionOverlay(panel)
        panels[id] = panel
        overlayHostings[id] = hosting

        if overlayObserver == nil {
            overlayObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    for (oid, _) in SurfaceManager.shared.overlayHostings {
                        if let p = SurfaceManager.shared.panels[oid] {
                            SurfaceManager.shared.positionOverlay(p)
                        }
                    }
                }
            }
        }
    }

    private func positionOverlay(_ panel: NSPanel) {
        guard let parent = panel.parent else { return }
        let height: CGFloat = 64
        panel.setFrame(
            NSRect(
                x: parent.frame.minX,
                y: parent.frame.maxY - height,
                width: parent.frame.width,
                height: height
            ),
            display: true
        )
    }

    // MARK: - Edge surfaces: a child window hugging a window edge, mostly
    // hidden (peek), sliding into view on cursor proximity. The slide is
    // manager physics; whatever renders inside is the mod's tree.

    private var edgeConfigs: [String: (edge: String, peek: Double, width: Double, attach: String)] = [:]
    private var edgeRevealed: Set<String> = []
    private var edgeCursor: [String: CursorModel] = [:]

    private func showEdge(
        id: String, edge: String, peek: Double, width: Double, attach: String, tree: [String: Any]
    ) {
        // A peek under 6px is invisible and unhittable.
        let peek = max(peek, 6)
        edgeConfigs[id] = (edge, peek, width, attach)
        let cursor = edgeCursor[id] ?? CursorModel()
        edgeCursor[id] = cursor
        let root = Self.edgeRoot(surfaceId: id, edge: edge, tree: tree, cursor: cursor)

        if let hosting = overlayHostings[id], let panel = panels[id] {
            hosting.rootView = root
            positionEdge(id: id, panel: panel, animated: false)
            return
        }

        guard let main = NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.windowController is BrowserWindowController })
        else { return }

        let panel = SurfacePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A fully transparent window lets WindowServer route clicks through
        // transparent favicon pixels before AppKit can hit-test them.
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.01)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        let container = EdgeTrackingView(surfaceId: id, cursor: cursor)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container

        if attach == "screen" {
            // The dock belongs to the screen, not the Space it was created
            // in. Joining all Spaces also avoids moving an inactive browser
            // window when the dock is revealed beside a fullscreen window.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.level = .floating
            panel.orderFront(nil)
        } else {
            main.addChildWindow(panel, ordered: .above)
        }
        panels[id] = panel
        overlayHostings[id] = hosting
        positionEdge(id: id, panel: panel, animated: false)
    }

    /// The mod's tree plus the primitive's own affordance: a drawer-handle
    /// capsule pinned to the inner edge, so the collapsed sliver is visible
    /// and inviting. Mod content never needs to know about collapse state.
    private static func edgeRoot(
        surfaceId: String, edge: String, tree: [String: Any], cursor: CursorModel
    ) -> AnyView {
        AnyView(
            ZStack(alignment: edge == "right" ? .leading : .trailing) {
                LiveSurfaceTree(surfaceId: surfaceId, node: tree, cursor: cursor)
                if surfaceId != "edge_dock" {
                    Capsule()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 3.5, height: 46)
                        .padding(edge == "right" ? .leading : .trailing, 1.5)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
            }
            .frame(maxHeight: .infinity)
        )
    }

    private var draggingEdges: Set<String> = []
    private var edgeHoldUntil: [String: TimeInterval] = [:]

    func setEdgeDragging(_ id: String, _ dragging: Bool) {
        if dragging {
            draggingEdges.insert(id)
            setEdgeRevealed(id, true)
        } else {
            draggingEdges.remove(id)
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            edgeHoldUntil[id] = deadline
            setEdgeRevealed(id, true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.edgeHoldUntil[id] == deadline else { return }
                self.edgeHoldUntil.removeValue(forKey: id)
                guard let panel = self.panels[id] else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.setEdgeRevealed(id, false) }
            }
        }
    }

    func setEdgeRevealed(_ id: String, _ revealed: Bool) {
        if !revealed && (draggingEdges.contains(id) ||
            (edgeHoldUntil[id] ?? 0) > ProcessInfo.processInfo.systemUptime) { return }
        guard let panel = panels[id] else { return }
        if revealed { edgeRevealed.insert(id) } else { edgeRevealed.remove(id) }
        positionEdge(id: id, panel: panel, animated: true)
    }

    /// Tab-switch pulse (bowser-browser-kt2): slide every edge surface out
    /// briefly so in-dock feedback (the active-icon bounce) is actually
    /// visible past the collapsed peek sliver, then retract. Generation
    /// token so overlapping pulses don't collapse early; a cursor already
    /// over the panel wins — retracting under the pointer would fight the
    /// proximity tracking.
    private var pulseGeneration = 0

    func pulseEdges(for seconds: TimeInterval = 1.4) {
        pulseGeneration += 1
        let generation = pulseGeneration
        for id in edgeConfigs.keys {
            setEdgeRevealed(id, true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.pulseGeneration == generation else { return }
            for id in self.edgeConfigs.keys {
                guard let panel = self.panels[id] else { continue }
                if !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                    self.setEdgeRevealed(id, false)
                }
            }
        }
    }

    private func positionEdge(id: String, panel: NSPanel, animated: Bool) {
        guard let config = edgeConfigs[id] else { return }

        // Reference frame: the parent window, or the screen for a
        // macOS-Dock-style screen-edge surface.
        let reference: NSRect
        let topInset: CGFloat
        if config.attach == "screen" {
            guard let screen = panel.screen ?? NSScreen.main else { return }
            reference = screen.visibleFrame
            topInset = 0
        } else {
            guard let parent = panel.parent else { return }
            reference = parent.frame
            topInset = 40
        }

        let width = CGFloat(config.width)
        let hidden = width - CGFloat(config.peek)
        let revealed = edgeRevealed.contains(id)

        // Collapsed window-attached surfaces park fully OUTSIDE the window:
        // overlapping the edge stole the window's resize zone.
        let x: CGFloat
        if config.edge == "right" {
            x = revealed
                ? reference.maxX - width
                : (config.attach == "screen" ? reference.maxX - CGFloat(config.peek) : reference.maxX + 1)
        } else {
            x = revealed
                ? reference.minX
                : (config.attach == "screen" ? reference.minX - hidden : reference.minX - width - 1)
        }

        let frame = NSRect(
            x: x, y: reference.minY,
            width: width, height: reference.height - topInset
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func show(id: String, title: String, anchor: String, width: Double, tree: [String: Any]) {
        let root = AnyView(LiveSurfaceTree(surfaceId: id, node: tree, title: title))

        if let panel = panels[id], let hosting = hostings[id] {
            // Update in place: SwiftUI diffs the tree; replacing the view
            // caused stuck-state artifacts. Width: the owner's (resized or
            // remembered) wins, else content-fit; height grows to fit
            // content but never fights a taller owner-set frame.
            hosting.rootView = root
            let natural = hosting.fittingSize
            let w = Self.preferredWidth(requested: width, natural: natural.width,
                                        remembered: userSized.contains(id) ? panel.frame.width : nil)
            let h = max(Self.fittedHeight(surfaceId: id, title: title, node: tree, width: w), userSized.contains(id) ? panel.frame.height : 0)
            panel.setContentSize(NSSize(width: w, height: h))
            panel.invalidateShadow()
            return
        }

        let hosting = NSHostingView(rootView: root)
        let natural = hosting.fittingSize
        let remembered = Self.rememberedFrame(id)
        if remembered != nil { userSized.insert(id) }
        let fitted = Self.preferredWidth(requested: width, natural: natural.width, remembered: remembered?.width)
        let height = max(Self.fittedHeight(surfaceId: id, title: title, node: tree, width: fitted), remembered?.height ?? 0)

        // .resizable on a borderless panel = edge-drag resizing, no title bar.
        let panel = SurfacePanel(
            contentRect: NSRect(x: 0, y: 0, width: fitted, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 220, height: 60)
        panel.maxSize = NSSize(width: Self.maxPanelWidth, height: 1400)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        // Independent of the browser window, NOT a child of it (the owner
        // found the glued-together "one window" behaviour annoying): the
        // .floating level keeps panels above the main window whenever Bowser
        // is active, hidesOnDeactivate takes them away with the app and
        // brings them back with it, and fullScreenAuxiliary lets them show
        // over a fullscreen main window without being its child.
        // NOT hidesOnDeactivate: that made every panel vanish the moment the
        // owner glanced at another app. Instead the level follows activation
        // (observeActivation): floating while Bowser is active, normal — a
        // plain window in the stack — when it is not.
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        observeActivation()

        let effect = NSVisualEffectView(frame: panel.contentLayoutRect)
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Layer cornerRadius does NOT round the behind-window backdrop —
        // the system composites a square blur/shadow region behind the
        // clipped layer. maskImage masks the backdrop itself.
        effect.maskImage = Self.roundedMask(radius: 14)
        effect.autoresizingMask = [.width, .height]

        hosting.autoresizingMask = [.width, .height]
        hosting.frame = effect.bounds
        effect.addSubview(hosting)
        panel.contentView = effect

        if let remembered, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(remembered) }) {
            panel.setFrameOrigin(remembered.origin)
        } else {
            position(panel, anchor: anchor)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
        panels[id] = panel
        hostings[id] = hosting
        rememberFrame(of: panel, id: id)
    }

    // MARK: - Windows remember themselves

    /// Content-fit width capped so a long hstack cannot run off the screen.
    nonisolated static let maxPanelWidth: CGFloat = 480

    /// Ids whose frame the owner set (resized/moved, or remembered): their
    /// width is never overridden by a re-render.
    private var userSized: Set<String> = []

    /// The width a panel gets: the owner's remembered/resized width wins;
    /// otherwise the larger of what the mod asked for and what the content
    /// needs, capped. Pure — tested.
    nonisolated static func preferredWidth(requested: CGFloat, natural: CGFloat, remembered: CGFloat?) -> CGFloat {
        if let remembered, remembered >= 220 { return min(remembered, maxPanelWidth) }
        return min(max(requested, natural.rounded(.up)), maxPanelWidth)
    }

    private static func frameKey(_ id: String) -> String { "BowserPanelFrame." + id }

    static func rememberedFrame(_ id: String) -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: frameKey(id)) else { return nil }
        let rect = NSRectFromString(text)
        return rect.width >= 220 && rect.height >= 40 ? rect : nil
    }

    /// Persist the frame whenever the owner moves or resizes the panel, so a
    /// re-show or a restart puts it back exactly where it was.
    private func rememberFrame(of panel: NSPanel, id: String) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            center.addObserver(forName: name, object: panel, queue: .main) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let panel else { return }
                    self?.userSized.insert(id)
                    UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey(id))
                }
            }
        }
    }

    /// Focus follows the main window: re-front every live surface. Only
    /// WINDOW-attached edges are children of the browser window (they hug
    /// its edge) — re-adopt those when their parent was closed. Floating
    /// panels and screen-attached edges are independent windows: front
    /// them, never re-parent them. Any panel that drifted off every screen
    /// gets rescued back beside the parent (bowser-browser-gpi).
    func orderAllFront(parent: NSWindow) {
        let next = BrowserWindowController.all.first(where: { $0.window === parent })?.profile.id ?? "default"
        if next != activeProfile {
            activeProfile = next
            for (id, message) in scopedMessages {
                if belongsToActiveProfile(id) {
                    handle(message)
                } else {
                    panels[id]?.parent?.removeChildWindow(panels[id]!)
                    panels[id]?.orderOut(nil)
                    SettingsWindow.shared.remove(id: id)
                }
            }
        }
        for (id, panel) in panels where panel !== parent && belongsToActiveProfile(id) {
            let screenAttached = edgeConfigs[id]?.attach == "screen"
            let windowAttachedEdge = edgeConfigs[id] != nil && !screenAttached
            // Edges keep their hosting view in overlayHostings too — a
            // toolbar overlay is one WITHOUT an edge config. Treating the
            // dock as an overlay re-parented it into the focused window and
            // laid it out as a 1200x64 strip over the title bar.
            if overlayHostings[id] != nil, edgeConfigs[id] == nil {
                // The toolbar overlay rides the FOCUSED window too.
                if panel.parent !== parent {
                    panel.parent?.removeChildWindow(panel)
                    parent.addChildWindow(panel, ordered: .above)
                    positionOverlay(panel)
                }
                continue
            }
            if windowAttachedEdge {
                // The edge rides with the FOCUSED window: re-parent when
                // another window takes focus. Ordering a child window front
                // raises its parent's whole group — with the dock still
                // parented to the previous window, every focus change (and
                // every app reactivation) shoved that window back on top.
                if panel.parent !== parent {
                    panel.parent?.removeChildWindow(panel)
                    parent.addChildWindow(panel, ordered: .above)
                    positionEdge(id: id, panel: panel, animated: false)
                }
                continue // children are ordered with their parent; never orderFront them
            }
            if !screenAttached,
               !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
                panel.setFrameOrigin(Self.clamped(panel.frame.origin,
                                                  size: panel.frame.size,
                                                  in: parent.screen?.visibleFrame))
            }
            if panel.parent == nil { panel.orderFront(nil) }
        }
    }

    /// Keep a panel origin on the screen, with a small margin. Nil visible
    /// frame (headless) passes the origin through.
    static func clamped(_ origin: NSPoint, size: NSSize, in visible: NSRect?) -> NSPoint {
        guard let visible else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8)),
            y: min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        )
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func position(_ panel: NSPanel, anchor: String) {
        guard let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            panel.center()
            return
        }
        let frame = main.frame
        let size = panel.frame.size
        let drop = 40 + CGFloat(panels.count) * (size.height + 20)
        // Anchors beside a fullscreen (or screen-hugging) window land past
        // the screen edge — clamp into the visible frame, overlapping the
        // window rather than vanishing (bowser-browser-gpi).
        let origin: NSPoint
        switch anchor {
        case "left_of_main":
            origin = NSPoint(x: frame.minX - size.width - 14, y: frame.maxY - size.height - drop)
        case "right_of_main":
            origin = NSPoint(x: frame.maxX + 14, y: frame.maxY - size.height - drop)
        default:
            panel.center()
            return
        }
        panel.setFrameOrigin(Self.clamped(origin, size: size, in: main.screen?.visibleFrame))
    }
}

/// Borderless panels refuse key status by default; allow it so text fields
/// in palettes can be edited (becomesKeyOnlyIfNeeded keeps buttons from
/// stealing focus).
private final class SurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Cursor plumbing for proximity widgets (magnify_strip etc.)

/// AppKit tracking host: .activeAlways tracking areas deliver mouseMoved
/// reliably even in never-key panels (the reason SwiftUI onHover was banned
/// here). Feeds CursorModel and drives the manager's reveal/collapse slide.
final class EdgeTrackingView: NSView {
    private let surfaceId: String
    private let cursor: CursorModel

    init(surfaceId: String, cursor: CursorModel) {
        self.surfaceId = surfaceId
        self.cursor = cursor
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    // Top-origin so cursor coordinates match SwiftUI's space directly.
    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Blank space between dock controls belongs to the dock as well.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func mouseEntered(with event: NSEvent) {
        SurfaceManager.shared.setEdgeRevealed(surfaceId, true)
    }

    override func mouseExited(with event: NSEvent) {
        cursor.point = nil
        SurfaceManager.shared.setEdgeRevealed(surfaceId, false)
    }

    override func mouseMoved(with event: NSEvent) {
        cursor.point = convert(event.locationInWindow, from: nil)
    }
}

