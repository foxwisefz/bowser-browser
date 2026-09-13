import AppKit
import CryptoKit
import Foundation

/// A native-launch journal: an evicted acknowledgement never makes an old
/// operation executable again. Reconnecting controllers reconcile from snapshot.
@MainActor final class NativeResourceJournal {
    let session: String
    private(set) var next = 1
    private var replies: [Int: (Data, [String: Any])] = [:]
    init(session: String) { self.session = session }

    func apply(_ message: [String: Any], execute: ([String: Any]) -> [String: Any]) -> [String: Any] {
        func failure(_ error: String) -> [String: Any] { ["ok": false, "error": error, "next": next] }
        guard message["version"] as? Int == 1, message["session"] as? String == session else { return failure("wrong_session_or_version") }
        guard let sequence = message["sequence"] as? Int, sequence > 0,
              let command = message["command"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: command, options: [.sortedKeys]), data.count <= 65536 else { return failure("invalid_command") }
        if let (original, reply) = replies[sequence] {
            return original == data ? reply : failure("sequence_conflict")
        }
        guard sequence == next, next < Int.max else { return failure(sequence < next ? "acknowledgement_expired" : "sequence_gap") }
        let result = execute(command)
        next += 1
        var reply = result
        reply["sequence"] = sequence; reply["next"] = next; reply["session"] = session
        replies[sequence] = (data, reply)
        replies.removeValue(forKey: sequence - 128)
        return reply
    }
}

/// Resource ownership stays here; callers supply policy decisions over stable IDs.
@MainActor final class NativeResources {
    let journal: NativeResourceJournal
    init(session: String) { journal = NativeResourceJournal(session: session) }
    func snapshot() -> [String: Any] {
        let windows: [[String: Any]] = BrowserWindowController.all.map { host in
            ["id": host.resourceID, "profile": host.profile.id,
             "tabs": host.tabs.map(\.webviewId), "active": host.activeTab?.webviewId ?? 0]
        }
        let data = (try? JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys])) ?? Data()
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ["version": 1, "session": journal.session, "next": journal.next, "revision": revision, "windows": windows]
    }
    func apply(_ message: [String: Any]) -> [String: Any] {
        journal.apply(message) { command in
            guard command["revision"] as? String == snapshot()["revision"] as? String else { return ["ok": false, "error": "stale_resources"] }
            guard let window = command["window"] as? String,
                  let profile = command["profile"] as? String,
                  let host = BrowserWindowController.all.first(where: { $0.resourceID == window && $0.profile.id == profile }),
                  let id = command["tab"] as? UInt64,
                  host.tabs.contains(where: { $0.webviewId == id }) else { return ["ok": false, "error": "unknown_resource"] }
            switch command["action"] as? String {
            case "activate":
                _ = host.activateTab(id: id)
            case "move":
                guard let target = command["target"] as? UInt64, let after = command["after"] as? Bool,
                      host.moveTab(id: id, relativeTo: target, after: after) else { return ["ok": false, "error": "invalid_move"] }
            case "close": host.closeTab(id: id)
            default: return ["ok": false, "error": "unknown_action"]
            }
            return ["ok": true]
        }
    }
}
