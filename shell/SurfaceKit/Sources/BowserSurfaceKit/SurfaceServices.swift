import AppKit
import SwiftUI

/// Stable host services; render generations receive data and UI-only handles.
/// WebKit objects and browser authority never enter the rendering library.
@MainActor public final class SurfaceServices: ObservableObject {
    public static let shared = SurfaceServices()
    public var emit: ([String: Any]) -> Void = { _ in }
    public var tabSnapshot: (UInt64) -> SurfaceTabSnapshot? = { _ in nil }
    public var closeTab: (UInt64) -> Bool = { _ in false }
    public var canMoveTab: (UInt64, UInt64) -> Bool = { _, _ in false }
    public var moveTab: (UInt64, UInt64, Bool) -> Bool = { _, _, _ in false }
    public var exportTab: (UInt64) throws -> URL = { _ in throw CocoaError(.fileNoSuchFile) }
    public var edgeDragging: (Bool) -> Void = { _ in }
    private var interactions = Set<UUID>()
    public var hasInteractions: Bool { !interactions.isEmpty }
    public func beginInteraction() -> UUID { let id = UUID(); interactions.insert(id); return id }
    public func endInteraction(_ id: UUID) { interactions.remove(id) }
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

/// Shared identity works across simultaneously mounted module generations.
@MainActor public protocol SurfaceTabDragSource: AnyObject { var draggedID: UInt64? { get } }
@MainActor public struct SurfaceTabSnapshot {
    public let icon: NSImage?
    public let canExport: Bool
    public init(icon: NSImage?, canExport: Bool) { self.icon = icon; self.canExport = canExport }
}
