import AppKit
import QuartzCore

/// A short, screen-space cloud that survives closing the tab's last window.
@MainActor
enum TabDustEffect {
    static func show(at point: NSPoint) {
        let size = NSSize(width: 180, height: 160)
        let panel = NSPanel(contentRect: NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        panel.contentView = view
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.18 : 0.55
        if let layer = view.layer { populate(layer, size: size, reducedMotion: reduced, duration: duration) }
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { panel.close() }
    }

    static func populate(_ layer: CALayer, size: NSSize, reducedMotion: Bool, duration: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Overlapping soft billows plus small flecks evoke the original Dock poof.
        for index in 0..<24 {
            let angle = Double(index) * 2.3999632297
            let billow = index < 10
            let radius = CGFloat(billow ? 22 : 3 + index % 4)
            let distance = CGFloat(billow ? 25 + index * 2 : 35 + index % 7 * 4)
            let particle = CALayer()
            particle.bounds = CGRect(x: 0, y: 0, width: radius, height: radius)
            particle.cornerRadius = radius / 2
            particle.backgroundColor = NSColor(calibratedWhite: billow ? 0.76 : 0.56, alpha: billow ? 0.5 : 0.8).cgColor
            particle.shadowColor = NSColor.white.cgColor
            particle.shadowOpacity = billow ? 0.35 : 0
            particle.shadowRadius = 5
            particle.position = center
            particle.opacity = 0
            layer.addSublayer(particle)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0.65, 0]
            fade.keyTimes = [0, 0.12, 0.45, 1]
            var animations: [CAAnimation] = [fade]
            if !reducedMotion {
                let travel = CABasicAnimation(keyPath: "position")
                travel.fromValue = NSValue(point: center)
                travel.toValue = NSValue(point: CGPoint(x: center.x + cos(angle) * distance,
                                                        y: center.y + sin(angle) * distance - 8))
                let expand = CABasicAnimation(keyPath: "transform.scale")
                expand.fromValue = 0.35
                expand.toValue = billow ? 1.5 : 0.6
                animations += [travel, expand]
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            particle.add(group, forKey: "dust")
        }
    }
}
