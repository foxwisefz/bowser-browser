import AppKit
import SwiftUI

/// One host-owned context per mounted root, shared across renderer generations.
@MainActor public final class SurfaceRenderContext: ObservableObject {
    public static var contexts: [String: SurfaceRenderContext] = [:]
    public let id = UUID().uuidString
    public let surfaceID: String
    @Published public var node: [String: Any]
    public let cursor: CursorModel?
    public var eventWebview: UInt64?
    public var title: String?
    public var panelContentOnly = false
    public var generation: UInt64 = 0
    public var namespace = ""
    public var palette: [String: Any] = [:]
    public var style: [String: Any] = [:]
    public var scheme: ColorScheme = .light
    public var contrast: ColorSchemeContrast = .standard
    public init(surfaceID: String, node: [String: Any], cursor: CursorModel? = nil) {
        self.surfaceID = surfaceID; self.node = node; self.cursor = cursor
    }
}

private struct SurfaceRenderOwnerKey: EnvironmentKey { static let defaultValue = "" }
private struct SurfaceRenderGenerationKey: EnvironmentKey { static let defaultValue: UInt64 = 0 }
public extension EnvironmentValues {
    var surfaceRenderOwner: String {
        get { self[SurfaceRenderOwnerKey.self] }
        set { self[SurfaceRenderOwnerKey.self] = newValue }
    }
    var surfaceRenderGeneration: UInt64 {
        get { self[SurfaceRenderGenerationKey.self] }
        set { self[SurfaceRenderGenerationKey.self] = newValue }
    }
}
