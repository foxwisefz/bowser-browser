import AppKit
import SwiftUI
import BowserSurfaceKit

struct BrowserScreenRoot: View {
    @ObservedObject var context: BrowserScreenContext
    var body: some View {
        switch context.kind {
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
