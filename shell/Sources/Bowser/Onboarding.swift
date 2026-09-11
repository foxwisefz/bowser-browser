import AppKit
import SwiftUI
import Darwin

struct RegistrationDevice: Codable, Equatable, Sendable {
    let model: String
    let architecture: String
    let macOSVersion: String
    let appVersion: String
    let appBuild: String

    static func current() -> Self {
        var length = 0
        sysctlbyname("hw.model", nil, &length, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(length, 1))
        let result = sysctlbyname("hw.model", &bytes, &length, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(model: result == 0 ? String(cString: bytes) : "unknown", architecture: "arm64",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development")
    }
}

struct RegistrationPolicy: Equatable, Sendable {
    let termsVersion: String
    let termsURL: URL
}

struct RegistrationRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let email: String
    let termsVersion: String
    let acceptedAt: Date
    var device: RegistrationDevice? = nil
    var trainingConsent: Bool = false
}

struct RegistrationReceipt: Codable, Equatable, Sendable {
    let registrationID: String
    var telemetryToken: String? = nil
    let request: RegistrationRequest
}

enum RegistrationFailure: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "Registration couldn’t be completed. Please try again." }
}

/// No default endpoint or first-run activation: launch policy and the service
/// contract must be configured before this form collects registration data.
struct RegistrationService: Sendable {
    let endpoint: URL

    func submit(_ registration: RegistrationRequest) async throws -> RegistrationReceipt {
        guard endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil else {
            throw RegistrationFailure.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(registration.requestID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(registration)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegistrationFailure.invalidResponse
        }
        struct Response: Decodable { let registrationID: String; let telemetryToken: String? }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard !result.registrationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RegistrationFailure.invalidResponse
        }
        return RegistrationReceipt(registrationID: result.registrationID, telemetryToken: result.telemetryToken, request: registration)
    }
}

struct RegistrationStore: Sendable {
    let directory: URL
    var file: URL { directory.appendingPathComponent("registration.json") }

    func save(_ receipt: RegistrationReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func load() throws -> RegistrationReceipt? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(RegistrationReceipt.self, from: Data(contentsOf: file))
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var email = ""
    @Published var acceptedTerms = false
    @Published var trainingConsent = false
    @Published private(set) var submitting = false
    @Published private(set) var error: String?
    @Published private(set) var receipt: RegistrationReceipt?
    let policy: RegistrationPolicy
    private let store: RegistrationStore
    private let register: @Sendable (RegistrationRequest) async throws -> RegistrationReceipt
    private var pending: RegistrationRequest?
    private let device: RegistrationDevice

    init(policy: RegistrationPolicy, store: RegistrationStore, device: RegistrationDevice = .current(),
         register: @escaping @Sendable (RegistrationRequest) async throws -> RegistrationReceipt) {
        self.policy = policy; self.store = store; self.register = register
        self.device = device
    }

    nonisolated static func normalizedEmail(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, !value.contains(where: { $0.isWhitespace }),
              value.range(of: #"^[^@<>]+@[^@<>.]+(?:\.[^@<>.]+)+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    var canSubmit: Bool { Self.normalizedEmail(email) != nil && acceptedTerms && !submitting && receipt == nil }

    func submit() async {
        guard canSubmit, let email = Self.normalizedEmail(email) else { return }
        submitting = true; error = nil
        defer { submitting = false }
        if pending?.email != email || pending?.trainingConsent != trainingConsent {
            pending = RegistrationRequest(requestID: UUID(), email: email,
                termsVersion: policy.termsVersion, acceptedAt: Date(),
                device: device, trainingConsent: trainingConsent)
        }
        guard let request = pending else { return }
        do {
            let result = try await register(request)
            guard result.request == request, !result.registrationID.isEmpty else { throw RegistrationFailure.invalidResponse }
            try store.save(result)
            receipt = result
            await Telemetry.shared.start(token: result.telemetryToken)
            await Telemetry.shared.record(.registration(id: result.request.requestID))
        } catch {
            // Never echo server bodies, URLs, emails or credentials into error text.
            self.error = "We couldn’t finish setup. Check your connection and try again."
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let finished: () -> Void
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 64, height: 64)
            Text(model.receipt == nil ? "Welcome to Bowser" : "You’re ready to browse")
                .font(.system(size: 28, weight: .semibold))
            if model.receipt != nil {
                Text("Your registration and Terms acceptance are saved.").foregroundStyle(.secondary)
                Button("Start browsing", action: finished).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Text("Enter your email to get started.").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email address").font(.headline)
                    TextField("you@example.com", text: $model.email)
                        .textFieldStyle(.roundedBorder).focused($emailFocused)
                        .accessibilityLabel("Email address").disabled(model.submitting)
                        .onSubmit { Task { await model.submit() } }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("I agree to the Terms of Service", isOn: $model.acceptedTerms)
                        .toggleStyle(.checkbox).disabled(model.submitting)
                    HStack(spacing: 18) {
                        Link("Terms of Service", destination: model.policy.termsURL)
                    }
                    Toggle("Help improve and train models (optional)", isOn: $model.trainingConsent)
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
