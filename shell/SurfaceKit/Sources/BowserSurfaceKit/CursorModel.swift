import AppKit
import SwiftUI
/// Cursor position within an edge surface, in the hosting view's coordinate
/// space (nil = cursor outside). Widgets read it via @EnvironmentObject.
public final class CursorModel: ObservableObject {
    public init() {}
    @Published public var point: CGPoint?
}

