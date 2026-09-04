import AppKit
import SwiftUI

/// The window controls, popped ABOVE the window on hover of ⌘K: a tiny
/// borderless child window sitting on the top edge, three lights on a small
/// arc. Native buttons cannot leave the window; these call the same actions
/// (performClose / miniaturize / zoom). Falls back to just below the band
/// when there is no room above (window at the menu bar, fullscreen).
@MainActor
final class WindowControlsPop {
    private weak var owner: NSWindow?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 92, height: 40)

    init(owner: NSWindow) { self.owner = owner }

    func set(shown: Bool) {
        hideWork?.cancel()
        if shown { show() } else {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func show() {
        guard let owner else { return }
        let panel = self.panel ?? make(owner: owner)
        let above = NSPoint(x: owner.frame.minX + 6, y: owner.frame.maxY - 8)
        let roomAbove = (owner.screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude) >= above.y + size.height
        // No room above: tuck it just under the band instead.
        let origin = roomAbove ? above : NSPoint(x: above.x, y: owner.frame.maxY - 34 - size.height)
        let start = NSRect(origin: NSPoint(x: origin.x, y: origin.y - 6), size: size)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            owner.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        })
    }

    private func make(owner: NSWindow) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.contentView = NSHostingView(rootView: LightsArc(
            onHover: { [weak self] in self?.set(shown: $0) },
            close: { [weak owner] in owner?.performClose(nil) },
            minimize: { [weak owner] in owner?.miniaturize(nil) },
            zoom: { [weak owner] in owner?.zoom(nil) }
        ))
        panel = p
        return p
    }
}

/// Three lights on a shallow arc (the middle one highest), with the
/// familiar close/minimize/zoom glyphs on hover.
private struct LightsArc: View {
    let onHover: (Bool) -> Void
    let close: () -> Void
    let minimize: () -> Void
    let zoom: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            light(.init(red: 1, green: 0.37, blue: 0.34), glyph: "xmark", action: close).offset(x: -26, y: 6)
            light(.init(red: 1, green: 0.74, blue: 0.18), glyph: "minus", action: minimize).offset(x: 0, y: -4)
            light(.init(red: 0.16, green: 0.78, blue: 0.29), glyph: "arrow.up.left.and.arrow.down.right", action: zoom).offset(x: 26, y: 6)
        }
        .frame(width: 92, height: 40)
        .contentShape(Rectangle())
        .onHover { h in hovering = h; onHover(h) }
    }

    private func light(_ color: Color, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                if hovering {
                    Image(systemName: glyph).font(.system(size: 7, weight: .black)).foregroundStyle(.black.opacity(0.55))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
