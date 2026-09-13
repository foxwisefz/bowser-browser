import AppKit
import Combine

@MainActor public struct NativeMenuContext {
    public let target: NSObject
    public let siteHost: String?
    public let targets: [String: NSObject]
    public let siteActions: [String]
    public init(target: NSObject, siteHost: String?, targets: [String: NSObject], siteActions: [String]) {
        self.target = target; self.siteHost = siteHost; self.targets = targets; self.siteActions = siteActions
    }
}
@MainActor public struct NativeMenus {
    public let main: NSMenu
    public let windows: NSMenu
    public let profiles: NSMenu?
    public let mods: NSMenu
    public init(main: NSMenu, windows: NSMenu, profiles: NSMenu?, mods: NSMenu) {
        self.main = main; self.windows = windows; self.profiles = profiles; self.mods = mods
    }
}
@MainActor public final class NativeUIState: ObservableObject {
    public var menus: ((NativeMenuContext) -> NativeMenus)?
    public var alert: ((String, [String: String]) -> NSAlert)?
    public var layout: ((WebsiteLayoutNode, NSRect, [UInt64: NSView]) -> NSView)?
    public var layoutChanged: () -> Void = {}
    public var changed: () -> Void = {}
    public init() {}
}
