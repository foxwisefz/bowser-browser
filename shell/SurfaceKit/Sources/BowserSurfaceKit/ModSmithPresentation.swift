import Foundation

public struct ModSmithTurn: Decodable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    public var status: String?
    public var notes: String?
    public var checks: [String]?
}

public struct ModSmithProject: Decodable, Identifiable {
    public let id: String
    public let name: String
    public let scope: String
    public let url: String
    public let status: String
    public let summary: String
    public let turns: [ModSmithTurn]
    public let files: [String]
    public let enabled: Bool
    public let canUndo: Bool
    public let undoLabel: String?
    enum CodingKeys: String, CodingKey {
        case id, name, scope, url, status, summary, turns, files, enabled
        case canUndo = "can_undo", undoLabel = "undo_label"
    }
    public var scopeLabel: String {
        switch scope {
        case "browser": return "Across Bowser"
        case "app": return "Only this app"
        default: return "\(URL(string: url)?.host ?? url) · includes subdomains"
        }
    }
    public var statusLabel: String {
        switch status {
        case "working": return "Working"
        case "partial": return "Partially complete"
        case "failed": return "Needs attention"
        case "needs_help": return "Needs more help"
        case "interrupted": return "Interrupted"
        case "restored": return files.isEmpty ? "Removed" : "Restored"
        case "ready": return "Ready to edit"
        default: return enabled ? "Active" : "Disabled"
        }
    }
}

public struct ModSmithExisting: Decodable, Identifiable {
    public let path: String
    public let name: String
    public let scope: String
    public let enabled: Bool
    public var id: String { path }
}

public struct ModSmithSnapshot: Decodable {
    public init() {}
    public var available_mods: [ModSmithExisting]? = nil
    public var projects: [ModSmithProject] = []
    public var selected: String?
    public var busy = false
    public var accepted: String?
    public var error: String?
    public var progress: [String] = []
    public var stage = "Inspecting page"
}

@MainActor public protocol ModSmithPresentation: AnyObject {
    var isSiteApp: Bool { get }
    var snapshot: ModSmithSnapshot { get }
    var draft: String { get set }
    var scope: String { get set }
    var connectionError: String? { get }
    var targetURL: String { get }
    var project: ModSmithProject? { get }
    func action(_ action: String, project: String?, path: String?)
    func submit()
}
public extension ModSmithPresentation {
    func action(_ action: String, project: String? = nil, path: String? = nil) {
        self.action(action, project: project, path: path)
    }
}
