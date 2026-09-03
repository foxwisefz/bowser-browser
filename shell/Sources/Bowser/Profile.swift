import AppKit
import CryptoKit
import WebKit

/// A browser profile: its own website data store (cookies, logins, storage),
/// a name, a title-bar tint and an icon. Every window is bound to exactly
/// one; tabs never cross. The brain owns the list (~/.bowser/profiles.json)
/// and pushes changes with the `profiles` op; the shell reads the same file
/// at launch so a cold start knows its profiles before the brain connects.
struct Profile: Codable, Equatable {
    let id: String
    let name: String
    var tint: String?
    var icon: String?
    var uuid: String?

    static let defaultProfile = Profile(id: "default", name: "Personal", tint: nil, icon: nil, uuid: nil)

    @MainActor static var all: [Profile] = load()

    @MainActor static func reload() { all = load() }

    @MainActor static func find(_ id: String?) -> Profile {
        all.first { $0.id == id } ?? defaultProfile
    }

    /// The brain's `profiles` op payload.
    @MainActor static func apply(_ raw: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let list = try? JSONDecoder().decode([Profile].self, from: data)
        else { return }
        all = ensureDefault(list)
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bowser/profiles.json")
    }

    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Profile].self, from: data)
        else { return [defaultProfile] }
        return ensureDefault(list)
    }

    nonisolated static func ensureDefault(_ list: [Profile]) -> [Profile] {
        let others = list.filter { $0.id != "default" }
        let def = list.first { $0.id == "default" } ?? defaultProfile
        return [def] + others
    }

    /// "🧪 Work" / "Work".
    var label: String { [icon, name].compactMap { $0 }.joined(separator: " ") }

    var color: NSColor? { Self.color(hex: tint) }

    /// #rrggbb (any case) -> color; anything else nil.
    nonisolated static func color(hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The default profile IS the pre-profiles Bowser (default store, so
    /// existing logins stay). Others get a persistent identified store.
    @MainActor var dataStore: WKWebsiteDataStore {
        if id == "default" { return .default() }
        return WKWebsiteDataStore(forIdentifier: Self.storeUUID(id: id, uuid: uuid))
    }

    /// The brain mints a uuid per profile; a profile without one (hand-edited
    /// file) gets a stable uuid derived from its id so its store never moves.
    nonisolated static func storeUUID(id: String, uuid: String?) -> UUID {
        if let uuid, let parsed = UUID(uuidString: uuid) { return parsed }
        let digest = Insecure.MD5.hash(data: Data(("bowser-profile:" + id).utf8))
        var bytes = Array(digest)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
