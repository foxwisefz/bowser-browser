import Foundation

/// The wire shape is closed: callers cannot attach page content or arbitrary fields.
struct TelemetryEvent: Codable, Sendable, Equatable {
    enum Operation: String, Codable { case create, refine, undo }
    enum Outcome: String, Codable { case succeeded, failed, cancelled }
    enum Category: String, Codable { case native, backend, mod, unknown }
    let eventID: UUID
    let name: String
    let occurredAt: Date
    let properties: [String: String]

    static func registration(id: UUID) -> Self { make("registration_completed", id: id) }
    static func modsmith(_ operation: Operation, _ outcome: Outcome) -> Self {
        var fields = ["operation": operation.rawValue, "outcome": outcome.rawValue]
        if outcome == .failed { fields["failureCategory"] = "unknown" }
        return make("modsmith_outcome", fields: fields)
    }
    static func crash(_ category: Category) -> Self { make("crash", fields: ["category": category.rawValue]) }
    private static func make(_ name: String, id: UUID = UUID(), fields: [String: String] = [:]) -> Self {
        func version(_ key: String) -> String {
            let value = Bundle.main.infoDictionary?[key] as? String ?? "development"
            return value.range(of: #"^[A-Za-z0-9._+\-]{1,64}$"#, options: .regularExpression) != nil ? value : "development"
        }
        return Self(eventID: id, name: name, occurredAt: Date(), properties: fields.merging([
            "appVersion": version("CFBundleShortVersionString"), "appBuild": version("CFBundleVersion")
        ]) { _, new in new })
    }
    var valid: Bool {
        let base: Set<String> = ["appVersion", "appBuild"]
        guard base.allSatisfy({ properties[$0]?.range(of: #"^[A-Za-z0-9._+\-]{1,64}$"#, options: .regularExpression) != nil }) else { return false }
        switch name {
        case "registration_completed": return Set(properties.keys) == base
        case "crash": return Set(properties.keys) == base.union(["category"]) && Category(rawValue: properties["category"] ?? "") != nil
        case "modsmith_outcome":
            let failed = properties["outcome"] == "failed"
            return Set(properties.keys) == base.union(failed ? ["operation", "outcome", "failureCategory"] : ["operation", "outcome"])
                && Operation(rawValue: properties["operation"] ?? "") != nil && Outcome(rawValue: properties["outcome"] ?? "") != nil
                && (!failed || properties["failureCategory"] == "unknown")
        default: return false
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum PrivateHTTP {
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else { throw URLError(.badURL) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

actor Telemetry {
    static let shared = Telemetry(directory: queueDirectory(home: BowserPaths.home, bundleID: Bundle.main.bundleIdentifier), endpoint: configuredEndpoint)
    nonisolated static func queueDirectory(home: URL, bundleID: String?) -> URL {
        let root = home.appendingPathComponent("telemetry")
        guard let bundleID, bundleID.range(of: #"^com\.foxwiseai\.bowser\.site\.[0-9a-f]{16}$"#, options: .regularExpression) != nil else { return root }
        return root.appendingPathComponent(bundleID)
    }
    private static var configuredEndpoint: URL? {
        if ProcessInfo.processInfo.environment["BOWSER_TELEMETRY_DISABLED"] == "1" { return nil }
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.foxwiseai.bowser") == true else { return nil }
        return URL(string: "https://bowser.app/v1/events")
    }
    typealias Sender = @Sendable (URLRequest) async throws -> Int
    private let directory: URL
    private let endpoint: URL?
    private let sender: Sender
    private var queue: [TelemetryEvent]
    private var flushing = false
    private var timer: Task<Void, Never>?
    private var delay: Double = 30
    private var token: String?

    init(directory: URL, endpoint: URL?, sender: @escaping Sender = { request in try await PrivateHTTP.send(request).1.statusCode }) {
        self.directory = directory; self.endpoint = endpoint; self.sender = sender
        let disk = try? Data(contentsOf: directory.appendingPathComponent("queue.json"))
        queue = (disk.flatMap { try? JSONDecoder().decode([TelemetryEvent].self, from: $0) } ?? []).filter { $0.valid && $0.occurredAt > Date().addingTimeInterval(-86400) }
        queue = Array(queue.suffix(100))
    }
    func start(token: String? = nil) async { self.token = token; await flush() }
    func record(_ event: TelemetryEvent) async {
        guard endpoint != nil, event.valid else { return }
        if !queue.contains(where: { $0.eventID == event.eventID }) { queue.append(event) }
        queue = Array(queue.suffix(100)); save()
        if timer == nil { await flush() }
    }
    func pending() -> [TelemetryEvent] { queue }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("queue.json")
            try JSONEncoder().encode(queue).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Telemetry never blocks browsing or logs payloads. */ }
    }
    func flush() async {
        guard let endpoint, endpoint.scheme == "https", !flushing else { return }
        timer?.cancel(); timer = nil
        flushing = true
        defer { flushing = false }
        queue.removeAll { $0.occurredAt < Date().addingTimeInterval(-86400) }; save()
        guard !queue.isEmpty else { return }
        let batch = Array(queue.prefix(25)), ids = Set(batch.map(\.eventID))
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        struct Batch: Encodable { let events: [TelemetryEvent] }
        request.httpBody = try? encoder.encode(Batch(events: batch))
        let status = (try? await sender(request)) ?? 0
        if status == 202 || [400, 409, 413, 415].contains(status) {
            queue.removeAll { ids.contains($0.eventID) }; save(); delay = 30
        } else if status == 401 { token = nil }
        if !queue.isEmpty {
            let wait = delay; delay = min(delay * 2, 3600)
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await self?.retry()
            }
        }
    }
    private func retry() async { timer = nil; await flush() }
}
