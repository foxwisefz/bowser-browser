import AppKit

public struct ProfileDraft: Equatable {
    public var name: String
    public var character: ProfileCharacter?
    public var tint: String?
    public var icon: String?

    public init(name: String, character: ProfileCharacter?, tint: String?, icon: String?) {
        self.name = name; self.character = character; self.tint = tint; self.icon = icon
    }

    public static var newProfile: ProfileDraft {
        var draft = ProfileDraft(name: "Default", character: .bowser, tint: nil, icon: nil)
        draft.name = ""
        draft.character = .bowser
        draft.tint = ProfileCharacter.bowser.tint
        draft.icon = nil
        return draft
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var payload: [String: Any] {
        ["name": trimmedName, "character": character?.rawValue as Any? ?? NSNull(),
         "tint": tint as Any? ?? NSNull()]
    }
}


public struct ProfileDisplay: Identifiable {
    public let id: String
    public let name: String
    public let draft: ProfileDraft
    public init(id: String, name: String, draft: ProfileDraft) { self.id = id; self.name = name; self.draft = draft }
}
@MainActor public protocol ProfilesPresentation: AnyObject {
    var displayProfiles: [ProfileDisplay] { get }
    var selectedID: String { get }
    var selectedDisplay: ProfileDisplay? { get }
    var draft: ProfileDraft { get set }
    var isPresentingCreate: Bool { get set }
    var isBusy: Bool { get }
    var error: String? { get }
    var notice: String? { get }
    var hasChanges: Bool { get }
    var canSave: Bool { get }
    func select(_ id: String)
    func confirmDiscardChanges() -> Bool
    func clearError()
    func revert()
    func save()
    func create(_ draft: ProfileDraft)
    func remove()
    func openWindow()
}
@MainActor public protocol DefaultBrowserPresentation: AnyObject {
    var statusText: String { get }
    var isSetting: Bool { get }
    var isDefault: Bool { get }
    var canSetDefault: Bool { get }
    func setDefault()
}
public struct SettingsSection: Identifiable, Equatable {
    public let id: String
    public var title: String
    public var order: Int
    public var tree: [String: Any]
    public init(id: String, title: String, order: Int, tree: [String: Any]) {
        self.id = id; self.title = title; self.order = order; self.tree = tree
    }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.title == b.title && a.order == b.order }
}
@MainActor public protocol SettingsPresentation: AnyObject {
    var sections: [SettingsSection] { get }
    var selected: String? { get }
    var profilesContext: BrowserScreenContext { get }
    var defaultContext: BrowserScreenContext { get }
}
