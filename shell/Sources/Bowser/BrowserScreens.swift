import AppKit
import SwiftUI
import BowserSurfaceKit

struct BrowserScreenRoot: View {
    @ObservedObject var context: BrowserScreenContext
    var body: some View {
        switch context.kind {
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
