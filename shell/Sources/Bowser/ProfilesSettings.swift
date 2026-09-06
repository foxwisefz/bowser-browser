import AppKit
import SwiftUI

struct ProfileDraft: Equatable {
    var name: String
    var character: ProfileCharacter?
    var tint: String?
    var legacyIcon: String?

    init(_ profile: Profile) {
        name = profile.name
        character = profile.avatar
        tint = profile.tint
        legacyIcon = profile.icon
    }

    static var newProfile: ProfileDraft {
        var draft = ProfileDraft(.defaultProfile)
        draft.name = ""
        draft.character = .bowser
        draft.tint = ProfileCharacter.bowser.tint
        draft.legacyIcon = nil
        return draft
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var payload: [String: Any] {
        ["name": trimmedName, "character": character?.rawValue as Any? ?? NSNull(),
         "tint": tint as Any? ?? NSNull()]
    }
}

@MainActor
final class ProfileSettingsModel: ObservableObject {
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
    @ObservedObject var model: ProfileSettingsModel
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep your browsing separate.").font(.system(size: 15, weight: .semibold))
                Text("Each profile has its own windows, website logins, and site data.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                profileList
                Divider()
                if model.selectedProfile != nil {
                    detail
                } else {
                    Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .padding(28)
        .sheet(isPresented: $model.isPresentingCreate) { NewProfileSheet(model: model) }
        .alert("Remove “\(model.selectedProfile?.name ?? "profile")”?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Profile", role: .destructive) { model.remove() }
        } message: {
            Text("Its saved website data will remain on this Mac. Any open windows will stay open until you close them.")
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: Binding<String?>(get: { model.selectedID }, set: { id in
                guard let id, id != model.selectedID, model.confirmDiscardChanges() else { return }
                model.select(id)
            })) {
                ForEach(model.profiles, id: \.id) { profile in
                    HStack(spacing: 10) {
                        ProfileIdentity(draft: ProfileDraft(profile), size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if profile.id == "default" {
                                Text("Default").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .tag(profile.id)
                }
            }
            .listStyle(.inset)
            .disabled(model.isBusy)
            Divider()
            HStack(spacing: 0) {
                Button {
                    if model.confirmDiscardChanges() { model.clearError(); model.isPresentingCreate = true }
                } label: { Image(systemName: "plus").frame(width: 32, height: 26) }
                .help("Add profile").accessibilityLabel("Add profile")
                Divider().frame(height: 16)
                Button { confirmRemoval = true } label: { Image(systemName: "minus").frame(width: 32, height: 26) }
                    .disabled(model.selectedID == "default" || model.isBusy)
                    .help("Remove profile").accessibilityLabel("Remove profile")
                Spacer()
                Text("\(model.profiles.count) \(model.profiles.count == 1 ? "profile" : "profiles")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.trailing, 8)
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 190)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                ProfileIdentity(draft: model.draft, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.draft.trimmedName.isEmpty ? "Untitled profile" : model.draft.trimmedName)
                        .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(model.selectedID == "default" ? "Your default browsing profile" : "A separate browsing profile")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider()
            ProfileSettingsFields(draft: $model.draft)
                .disabled(model.isBusy)
            Text("The character and color identify this profile’s windows. You can change them anytime.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            } else if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Window") {
                    if let profile = model.selectedProfile { (NSApp.delegate as? AppDelegate)?.openWindow(profile: profile) }
                }
                .disabled(model.isBusy)
                Spacer()
                if model.hasChanges {
                    Button("Revert") { model.revert() }.disabled(model.isBusy)
                }
                Button(model.isBusy ? "Saving…" : "Save Changes") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ProfileIdentity: View {
    let draft: ProfileDraft
    let size: CGFloat
    var body: some View {
        Group {
            if let character = draft.character { ProfileCharacterPortrait(character: character, size: size) }
            else if let emoji = draft.legacyIcon { Text(emoji).font(.system(size: size * 0.7)) }
            else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary).frame(width: size, height: size) }
        }.frame(width: size, height: size)
    }
}

struct ProfileSettingsFields: View {
    @Binding var draft: ProfileDraft
    @State private var showCharacters = false
    private let colors = ["#e5484d", "#f76b15", "#d6a424", "#30a46c", "#12a594", "#3e63dd", "#8e4ec6", "#d6409f"]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 22) {
            GridRow {
                Text("Name:").gridColumnAlignment(.trailing)
                TextField("Profile name", text: $draft.name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Profile name")
            }
            GridRow {
                Text("Character:")
                Button { showCharacters = true } label: {
                    HStack(spacing: 8) {
                        ProfileIdentity(draft: draft, size: 32)
                        Text(draft.character?.title ?? "Choose a character")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).padding(.horizontal, 5)
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showCharacters, arrowEdge: .bottom) {
                    NativeProfileCharacterChooser(selected: draft.character) { character in
                        draft.character = character
                        draft.legacyIcon = nil
                        showCharacters = false
                    }
                }
            }
            GridRow {
                Text("Color:")
                HStack(spacing: 7) {
                    ForEach(colors, id: \.self) { hex in
                        Button { draft.tint = hex } label: {
                            Circle().fill(Color(nsColor: Profile.color(hex: hex)!))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if draft.tint == hex {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                        }.buttonStyle(.plain)
                            .accessibilityLabel(colorName(hex))
                            .accessibilityValue(draft.tint == hex ? "Selected" : "Not selected")
                            .help(colorName(hex))
                    }
                    Divider().frame(height: 20)
                    ColorPicker("Custom color", selection: Binding(get: {
                        Color(nsColor: Profile.color(hex: draft.tint) ?? .systemGray)
                    }, set: { draft.tint = SurfaceColorPickerHexBridge.hex(NSColor($0)) }), supportsOpacity: false)
                    .labelsHidden().fixedSize().help("Custom color")
                }
            }
        }
        .font(.system(size: 13))
    }

    private func colorName(_ hex: String) -> String {
        ["#e5484d": "Red", "#f76b15": "Orange", "#d6a424": "Yellow", "#30a46c": "Green",
         "#12a594": "Teal", "#3e63dd": "Blue", "#8e4ec6": "Purple", "#d6409f": "Pink"][hex] ?? "Color"
    }
}

struct NativeProfileCharacterChooser: View {
    let selected: ProfileCharacter?
    let choose: (ProfileCharacter) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a character").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 6), count: 6), spacing: 8) {
                ForEach(ProfileCharacter.allCases) { character in
                    Button { choose(character) } label: {
                        VStack(spacing: 4) {
                            ProfileCharacterPortrait(character: character, size: 40)
                            Text(character.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(width: 68, height: 66)
                        .background(selected == character ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected == character ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(character.title)
                        .accessibilityValue(selected == character ? "Selected" : "Not selected")
                }
            }
        }.padding(18)
    }
}

struct NewProfileSheet: View {
    @ObservedObject var model: ProfileSettingsModel
    @State private var draft = ProfileDraft.newProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                ProfileIdentity(draft: draft, size: 56)
                VStack(alignment: .leading, spacing: 7) {
                    Text("New Profile").font(.system(size: 20, weight: .semibold))
                    Text("Start fresh with separate website logins and site data. Your new profile opens in its own window.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            ProfileSettingsFields(draft: $draft).disabled(model.isBusy)
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { model.clearError(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button(model.isBusy ? "Creating…" : "Create Profile") { model.create(draft) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(draft.trimmedName.isEmpty || model.isBusy)
            }
        }
        .padding(28)
        .frame(width: 550)
        .interactiveDismissDisabled(model.isBusy)
    }
}
