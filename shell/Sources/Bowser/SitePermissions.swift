import AppKit
import WebKit

struct SitePermissionKey: Codable, Hashable {
    let profile: String
    let origin: String
    let kind: String
    static let kinds = ["camera", "microphone", "notifications"]
    static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else { return nil }
        let port = url.port
        let suffix = port == nil || port == (scheme == "https" ? 443 : 80) ? "" : ":\(port!)"
        return "\(scheme)://\(host)\(suffix)"
    }
    static func origin(_ security: WKSecurityOrigin) -> String? {
        var parts = URLComponents()
        parts.scheme = security.protocol; parts.host = security.host
        if security.port != 0 { parts.port = security.port }
        return origin(parts.url)
    }
    static func validRequest(top: String?, request: String?, frame: String?) -> Bool {
        guard let top, let request, let frame else { return false }
        return top == request && request == frame
    }
}

@MainActor final class SitePermissionStore {
    static let shared = SitePermissionStore(file: (SiteAppConfiguration.current?.home ?? BowserPaths.home).appendingPathComponent("site-permissions.json"))
    struct Entry: Codable { let key: SitePermissionKey; let decision: String }
    private let file: URL
    private(set) var revision: UInt64 = 0
    private(set) var entries: [SitePermissionKey: String] = [:]
    static let changed = Notification.Name("BowserSitePermissionsChanged")
    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), data.count <= 1_048_576,
           let rows = try? JSONDecoder().decode([Entry].self, from: data) {
            for row in rows where Self.valid(row.key) && ["allow", "block"].contains(row.decision) {
                entries[row.key] = row.decision
            }
        }
    }
    private static func valid(_ key: SitePermissionKey) -> Bool {
        !key.profile.isEmpty && key.profile.count <= 128 && SitePermissionKey.kinds.contains(key.kind)
            && SitePermissionKey.origin(URL(string: key.origin)) == key.origin
    }
    func decision(profile: String, origin: String, kind: String) -> String {
        entries[SitePermissionKey(profile: profile, origin: origin, kind: kind)] ?? "ask"
    }
    func set(profile: String, origin: String, kinds: [String], decision: String) throws {
        guard ["ask", "allow", "block"].contains(decision), !kinds.isEmpty,
              kinds.allSatisfy({ Self.valid(SitePermissionKey(profile: profile, origin: origin, kind: $0)) }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var next = entries
        for kind in kinds { next[SitePermissionKey(profile: profile, origin: origin, kind: kind)] = decision == "ask" ? nil : decision }
        try persist(next)
    }
    func reset(profile: String, kind: String? = nil) throws {
        try persist(entries.filter { $0.key.profile != profile || (kind != nil && $0.key.kind != kind) })
    }
    private func persist(_ next: [SitePermissionKey: String]) throws {
        guard next.count <= 4096 else { throw CocoaError(.fileWriteOutOfSpace) }
        try PrivateIPC.prepareDirectory(file.deletingLastPathComponent())
        let data = try JSONEncoder().encode(next.map { Entry(key: $0.key, decision: $0.value) })
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next; revision += 1
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func mediaDecision(profile: String, origin: String, kinds: [String]) -> WKPermissionDecision {
        let values = kinds.map { decision(profile: profile, origin: origin, kind: $0) }
        if values.contains("block") { return .deny }
        return !values.isEmpty && values.allSatisfy { $0 == "allow" } ? .grant : .prompt
    }
}
