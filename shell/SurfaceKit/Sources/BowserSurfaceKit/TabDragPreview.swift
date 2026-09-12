import AppKit
import SwiftUI
@MainActor
public final class TabDragPreview: ObservableObject {
    public init() {}
    public static let shared = TabDragPreview()
    @Published public var source: UInt64?
    @Published public var target: UInt64?
    @Published public var after = false

    public func gap(for id: UInt64, after edge: Bool, size: CGFloat) -> CGFloat {
        target == id && after == edge ? size : 0
    }
    public func clear(target id: UInt64) {
        if target == id { target = nil }
    }
    public func finish() { source = nil; target = nil }
}

