import AppKit
import SwiftUI
import BowserSurfaceKit

struct BrowserScreenRoot: View {
    @ObservedObject var context: BrowserScreenContext
    var body: some View {
        switch context.kind {
        case "settings": SettingsScreen(context: context)
        case "profiles": ProfilesScreen(context: context)
        case "modsmith": ModSmithScreen(context: context)
        case "onboarding": OnboardingScreen(context: context)
        default: EmptyView()
        }
    }
}

struct OnboardingScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any OnboardingPresentation { context.model as! any OnboardingPresentation }
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 64, height: 64)
            Text(!model.completed ? "Welcome to Bowser" : "You’re ready to browse")
                .font(.system(size: 28, weight: .semibold))
            if model.completed {
                Text("Your registration and Terms acceptance are saved.").foregroundStyle(.secondary)
                Button("Start browsing", action: model.finish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Text("Enter your email to get started.").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email address").font(.headline)
                    TextField("you@example.com", text: Binding(get: { model.email }, set: { model.email = $0 }))
                        .textFieldStyle(.roundedBorder).focused($emailFocused)
                        .accessibilityLabel("Email address").disabled(model.submitting)
                        .onSubmit { Task { await model.submit() } }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("I agree to the Terms of Service", isOn: Binding(get: { model.acceptedTerms }, set: { model.acceptedTerms = $0 }))
                        .toggleStyle(.checkbox).disabled(model.submitting)
                    HStack(spacing: 18) {
                        Link("Terms of Service", destination: model.termsURL)
                    }
                    Toggle("Help improve and train models (optional)", isOn: Binding(get: { model.trainingConsent }, set: { model.trainingConsent = $0 }))
                        .toggleStyle(.checkbox).disabled(model.submitting)
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if model.submitting { ProgressView().controlSize(.small).accessibilityLabel("Finishing setup") }
                    Button(model.submitting ? "Finishing setup…" : "Continue") {
                        Task { await model.submit() }
                    }.buttonStyle(.borderedProminent).disabled(!model.canSubmit).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(36).frame(width: 480, alignment: .leading)
        .onAppear { emailFocused = true }
    }
}

struct ModSmithScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any ModSmithPresentation { context.model as! any ModSmithPresentation }
    @FocusState private var composerFocused: Bool
    private var showDetails: Bool {
        get { context.binding("showDetails", default: false).wrappedValue }
        nonmutating set { context.binding("showDetails", default: false).wrappedValue = newValue }
    }
    private var showExisting: Bool {
        get { context.binding("showExisting", default: false).wrappedValue }
        nonmutating set { context.binding("showExisting", default: false).wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                conversation
                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { composerFocused = true }
        .sheet(isPresented: context.binding("showExisting", default: false)) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Continue working on a mod").font(.title2.weight(.semibold))
                Text("Choose an installed mod. Its existing conversation will reopen when available.").foregroundStyle(.secondary)
                if (model.snapshot.available_mods ?? []).isEmpty {
                    Text("No installed mods are available in this window yet.").padding(.vertical, 24)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.snapshot.available_mods ?? []) { mod in
                                Button {
                                    model.action("edit_existing", path: mod.path)
                                    showExisting = false
                                    composerFocused = true
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(mod.name).font(.headline)
                                            Text(mod.scope).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(mod.enabled ? "Enabled" : "Disabled").font(.caption)
                                        Image(systemName: "chevron.right")
                                    }.padding(12).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 300)
                }
                HStack { Spacer(); Button("Cancel") { showExisting = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 440)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your mods", systemImage: "sparkles").font(.headline).padding(.top, 8)
            Button { model.action("new") } label: {
                Label("New mod", systemImage: "plus").frame(maxWidth: .infinity)
            }.controlSize(.large)
            Button("Edit existing mod…", systemImage: "square.and.pencil") {
                model.action("open")
                showExisting = true
            }.controlSize(.small)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.snapshot.projects) { project in
                        Button { model.action("select", project: project.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(project.statusLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(model.snapshot.selected == project.id ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Changes happen live.\nMake a mod, then make it yours.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(16).frame(width: 190).background(.quaternary.opacity(0.25))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.project?.name ?? "What would you change?")
                .font(.system(size: 20, weight: .semibold)).lineLimit(2)
            if let project = model.project {
                HStack {
                    Label(project.scopeLabel, systemImage: project.scope == "browser" ? "macwindow" : "globe")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(project.statusLabel).font(.caption.weight(.medium))
                }
                HStack {
                    if project.canUndo {
                        Button("Undo last change", systemImage: "arrow.uturn.backward") { model.action("undo") }
                            .help("Restore mod files before: \(project.undoLabel ?? "last change"). Website actions and stored mod data are not reversed.")
                    }
                    if !project.files.isEmpty {
                        Button(project.enabled ? "Disable" : "Enable", systemImage: project.enabled ? "pause.circle" : "play.circle") {
                            model.action("toggle")
                        }
                    }
                }.controlSize(.small).disabled(model.snapshot.busy)
                if project.canUndo {
                    Text("Undo restores mod files. Website actions and saved mod data stay as they are.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if model.isSiteApp {
                Label("Only this app", systemImage: "app").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Applies to", selection: Binding(get: { model.scope }, set: { model.scope = $0 })) {
                    Text("This site").tag("site")
                    Text("Across Bowser").tag("browser")
                }.pickerStyle(.segmented).frame(maxWidth: 270)
                Text(model.scope == "browser" ? "Browser-wide customization" : "\(URL(string: model.targetURL)?.host ?? "Open a website") · includes subdomains")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let project = model.project {
                        if project.turns.isEmpty {
                            Text("What would you like to change about this mod?").font(.headline)
                            Text("Describe the next change below. Your existing files will be refined in place.").foregroundStyle(.secondary)
                        }
                        ForEach(project.turns) { turn in turnView(turn) }
                        if project.status == "interrupted" || project.status == "restored" {
                            Text(project.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                            Text("A small change.\nA browser that feels like you.")
                                .font(.system(size: 25, weight: .medium, design: .rounded))
                            Text("Describe what you want. Try it on the page, then keep refining the same mod.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(["Hide distractions and leave only the main content", "Make this page easier to read"], id: \.self) { example in
                                Button { model.draft = example; composerFocused = true } label: {
                                    HStack { Text(example); Spacer(); Image(systemName: "arrow.up.left") }
                                        .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 25)
                    }
                    if model.project?.status == "working" {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.snapshot.stage).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !model.snapshot.progress.isEmpty && model.project?.status == "working" {
                        DisclosureGroup("Activity details", isExpanded: context.binding("showDetails", default: false)) {
                            Text(model.snapshot.progress.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.project?.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.snapshot.selected) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func turnView(_ turn: ModSmithTurn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(turn.role == "user" ? "You" : turn.role == "system" ? "Revision history" : "ModSmith")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(turn.text).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = turn.notes, !notes.isEmpty {
                DisclosureGroup("Details and limitations") {
                    Text(notes).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            if let checks = turn.checks {
                if checks.isEmpty {
                    Text("No verification reported.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Checks reported by the agent").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        Label(check, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(turn.role == "user" ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.connectionError ?? model.snapshot.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            TextField(model.project == nil ? "Describe your mod…" : "What should we change next?", text: Binding(get: { model.draft }, set: { model.draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...6).focused($composerFocused)
                .padding(13).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack {
                Text(model.snapshot.busy ? "A change is running. You can draft the next one." : "⌘ Return to send")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.project == nil ? "Create mod" : "Refine mod", systemImage: "arrow.up") { model.submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.snapshot.busy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).background(.bar)
    }
}

struct SettingsScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any SettingsPresentation { context.model as! any SettingsPresentation }

    var body: some View {
        Group {
            if model.selected == "profiles" {
                ProfilesScreen(context: model.profilesContext)
            } else if let section = model.sections.first(where: { $0.id == model.selected }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if section.id == "settings" {
                            DefaultBrowserScreen(context: model.defaultContext)
                        }
                        SurfaceTreeView(surfaceId: section.id, node: section.tree)
                            .id(section.id)
                    }
                    .padding(32)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView("Loading settings…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DefaultBrowserScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any DefaultBrowserPresentation { context.model as! any DefaultBrowserPresentation }

    var body: some View {
        GroupBox("Default Browser") {
            HStack(spacing: 16) {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isSetting {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.isDefault {
                    Button("Set as Default Browser") { model.setDefault() }
                        .disabled(!model.canSetDefault)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
struct ProfilesScreen: View {
    @ObservedObject var context: BrowserScreenContext
    private var model: any ProfilesPresentation { context.model as! any ProfilesPresentation }
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
                if model.selectedDisplay != nil {
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
        .sheet(isPresented: Binding(get: { model.isPresentingCreate }, set: { model.isPresentingCreate = $0 })) { NewProfileSheet(context: context) }
        .alert("Remove “\(model.selectedDisplay?.name ?? "profile")”?", isPresented: $confirmRemoval) {
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
                ForEach(model.displayProfiles, id: \.id) { profile in
                    HStack(spacing: 10) {
                        ProfileIdentity(draft: profile.draft, size: 30)
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
                Text("\(model.displayProfiles.count) \(model.displayProfiles.count == 1 ? "profile" : "profiles")")
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
            ProfileSettingsFields(draft: Binding(get: { model.draft }, set: { model.draft = $0 }))
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
                    model.openWindow()
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
            if let character = draft.character { SurfaceServices.shared.portrait(character.rawValue, size) }
            else if let emoji = draft.icon { Text(emoji).font(.system(size: size * 0.7)) }
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
                        draft.icon = nil
                        showCharacters = false
                    }
                }
            }
            GridRow {
                Text("Color:")
                HStack(spacing: 7) {
                    ForEach(colors, id: \.self) { hex in
                        Button { draft.tint = hex } label: {
                            Circle().fill(Color(nsColor: screenColor(hex: hex)!))
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
                        Color(nsColor: screenColor(hex: draft.tint) ?? .systemGray)
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
                            SurfaceServices.shared.portrait(character.rawValue, 40)
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
    @ObservedObject var context: BrowserScreenContext
    private var model: any ProfilesPresentation { context.model as! any ProfilesPresentation }
    private var draft: ProfileDraft {
        get { context.binding("newProfileDraft", default: ProfileDraft.newProfile).wrappedValue }
        nonmutating set { context.binding("newProfileDraft", default: ProfileDraft.newProfile).wrappedValue = newValue }
    }
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
            ProfileSettingsFields(draft: context.binding("newProfileDraft", default: ProfileDraft.newProfile)).disabled(model.isBusy)
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

private func screenColor(hex: String?) -> NSColor? {
    guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}
