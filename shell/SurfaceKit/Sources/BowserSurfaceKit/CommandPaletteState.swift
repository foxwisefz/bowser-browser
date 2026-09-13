import AppKit
import Combine

@MainActor public protocol BrowserScreenActivating: AnyObject { func activateScreen() }

@MainActor public final class CommandPaletteState: ObservableObject {
public struct TabCandidate: Equatable {
    public init(id: UInt64, title: String, url: String, profile: String, favicon: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.profile = profile; self.favicon = favicon
    }
    public let id: UInt64
    public let title: String
    public let url: String
    public let profile: String
    public var favicon: String? = nil
  }
public struct Result: Equatable {
    public init(tab: TabCandidate?, query: String) { self.tab = tab; self.query = query }

    public let tab: TabCandidate?
    public let query: String
    public var title: String {
      tab.map { $0.title.isEmpty ? ($0.url.isEmpty ? "New Tab" : $0.url) : $0.title }
        ?? "Open or search: \(query)"
    }
    public var detail: String { tab.map { "Switch to tab · \($0.url)" } ?? "Open in a new tab" }
  }


    public var results: [Result] = []
    public var query = ""
    public var placeholder = "Search, address, or :command"
    public var selected = 0
    public var profile = "default"
    public var active: UInt64?
    public var tabs: () -> [TabCandidate] = { [] }
    public var commands: () -> [String: String] = { [:] }
    public var choose: (Result) -> Void = { _ in }
    public var command: (String) -> Void = { _ in }
    public var dismiss: () -> Void = {}
    public var resize: (CGFloat) -> Void = { _ in }
    public var refresh: () -> Void = {}
    public var focus: () -> Void = {}
    public init() {}
}
