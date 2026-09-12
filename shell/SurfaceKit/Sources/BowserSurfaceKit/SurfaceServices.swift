import AppKit
import SwiftUI

/// Stable host services; render generations receive data and UI-only handles.
/// WebKit objects and browser authority never enter the rendering library.
@MainActor public final class SurfaceServices: ObservableObject {
    public static let shared = SurfaceServices()
    public var emit: ([String: Any]) -> Void = { _ in }
    public var dragView: (UInt64, @escaping () -> Void) -> NSView = { _, _ in NSView() }
    public var portrait: (String, CGFloat) -> AnyView = { _, _ in AnyView(EmptyView()) }
    @Published public var profiles: [SurfaceProfile] = []
    public var presentations = 0
    nonisolated public static func color(hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
public struct SurfaceProfile {
    public let id: String
    public let name: String
    public let tint: String?
    public let icon: String?
    public let avatar: String?
    public init(id: String, name: String, tint: String?, icon: String?, avatar: String?) {
        self.id = id; self.name = name; self.tint = tint; self.icon = icon; self.avatar = avatar
    }
}
private struct SurfaceDispatchKey: EnvironmentKey {
    static let defaultValue: @MainActor ([String: Any]) -> Void = { SurfaceServices.shared.emit($0) }
}
public extension EnvironmentValues {
    var surfaceDispatch: @MainActor ([String: Any]) -> Void {
        get { self[SurfaceDispatchKey.self] }
        set { self[SurfaceDispatchKey.self] = newValue }
    }
}
