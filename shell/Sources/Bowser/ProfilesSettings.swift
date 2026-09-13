import BowserSurfaceKit
import AppKit
import SwiftUI

extension ProfileDraft {
    init(_ profile: Profile) {
        self.init(name: profile.name, character: profile.avatar, tint: profile.tint, icon: profile.icon)
    }

}

@MainActor
final class ProfileSettingsModel: ObservableObject, ProfilesPresentation {
    var displayProfiles: [ProfileDisplay] { profiles.map { ProfileDisplay(id: $0.id, name: $0.name, draft: ProfileDraft($0)) } }
    var selectedDisplay: ProfileDisplay? { displayProfiles.first { $0.id == selectedID } }
    func openWindow() { if let profile = selectedProfile { (NSApp.delegate as? AppDelegate)?.openWindow(profile: profile) } }

    static let shared = ProfileSettingsModel()
    @Published private(set) var profiles: [Profile]
    @Published private(set) var selectedID: String
    @Published var draft: ProfileDraft
    @Published var isPresentingCreate = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published var notice: String?
    private var pending: (id: String, action: String)?
    private let send: ([String: Any]) -> Void

    init(profiles: [Profile]? = nil, send: (([String: Any]) -> Void)? = nil) {
        let list = profiles ?? Profile.all
        self.profiles = list
        let first = list.first ?? .defaultProfile
        selectedID = first.id
        draft = ProfileDraft(first)
        self.send = send ?? { BrainBridge.shared.send($0) }
    }

    var selectedProfile: Profile? { profiles.first { $0.id == selectedID } }
    var hasChanges: Bool { selectedProfile.map { ProfileDraft($0) != draft } ?? false }
    var canSave: Bool { hasChanges && !draft.trimmedName.isEmpty && !isBusy }

    func replaceProfiles(_ values: [Profile]) {
        let wasClean = !hasChanges
        profiles = values
        SurfaceHostServices.profiles(values)
        if selectedProfile == nil {
            select(values.first?.id ?? "default")
        } else if wasClean && !isBusy, let selectedProfile {
            draft = ProfileDraft(selectedProfile)
        }
    }

    func select(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        selectedID = id
        draft = ProfileDraft(profile)
        error = nil
    }

    func revert() { if let profile = selectedProfile { draft = ProfileDraft(profile) }; error = nil }
    func clearError() { error = nil }

    func confirmDiscardChanges() -> Bool {
        guard !isBusy else { return false }
        guard hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved profile changes?"
        alert.informativeText = "Your changes to this profile haven’t been saved."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        revert()
        return true
    }

    func save() { guard canSave else { return }; request("update", values: draft.payload.merging(["id": selectedID]) { _, new in new }) }
    func create(_ draft: ProfileDraft) { request("create", values: draft.payload) }
    func remove() { guard selectedID != "default" else { return }; request("delete", values: ["id": selectedID]) }

    private func request(_ action: String, values: [String: Any]) {
        guard !isBusy else { return }
        let id = UUID().uuidString
        pending = (id, action)
        isBusy = true
        error = nil
        notice = nil
        send(["op": "event", "event": "profile_settings", "action": action, "request_id": id, "values": values])
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.pending = nil
            self.isBusy = false
            self.error = "Bowser didn’t respond. Please try again."
        }
    }

    func receive(_ message: [String: Any]) {
        guard let pending, message["request_id"] as? String == pending.id else { return }
        self.pending = nil
        isBusy = false
        guard message["ok"] as? Bool == true else {
            error = message["error"] as? String ?? "The profile could not be saved."
            return
        }
        error = nil
        if pending.action == "create" { isPresentingCreate = false }
        select(message["profile_id"] as? String ?? selectedID)
        if selectedProfile == nil { select(profiles.first?.id ?? "default") }
        revert()
    }
}

struct ProfilesSettingsView: View {
    let model: ProfileSettingsModel
    var body: some View { LiveBrowserScreen(kind: "profiles", model: model) }
}
