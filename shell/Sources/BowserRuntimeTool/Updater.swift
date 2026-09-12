import Foundation
import Darwin
import BackendRuntime

func command(_ executable: String, _ args: [String]) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
func field(_ manifest: Message, _ key: String) throws -> URL {
    guard let path = manifest[key] as? String, path.hasPrefix("/") else { throw RuntimeFailure("missing absolute path: \(key)") }
    return URL(fileURLWithPath: path)
}
func home(_ manifest: Message) throws -> URL {
    if let path = manifest["home"] as? String { return URL(fileURLWithPath: path) }
    return try field(manifest, "runtime").deletingLastPathComponent()
}
func busy(_ manifest: Message) throws -> Bool {
    let owner = child(try home(manifest), "backend/owner.lock")
    if exists(owner) {
        guard let lock = try? FileLock(owner, nonblocking: true) else { return true }
        withExtendedLifetime(lock) {}
    }
    let roots = try [field(manifest, "bundle").path + "/", field(manifest, "runtime").path + "/",
                     (manifest["saved_apps"] as? String ?? child(FileManager.default.homeDirectoryForCurrentUser, "Applications/Bowser Apps").path) + "/",
                     child(home(manifest), "releases").path + "/"]
    return try command("/bin/ps", ["-axo", "comm="]).split(separator: "\n").contains { line in
        let path = line.trimmingCharacters(in: .whitespaces)
        return roots.contains { path.hasPrefix($0) }
    }
}
func activate(_ manifest: Message) throws {
    var changed: [(URL, URL, Bool, URL)] = []
    do {
        for key in ["runtime", "bundle"] {
            let source = child(try field(manifest, "stage"), key)
            if !exists(source) { continue }
            let target = try field(manifest, key)
            let previous = target.appendingPathExtension("previous")
            try remove(previous)
            let existed = exists(target)
            if existed { try FileManager.default.moveItem(at: target, to: previous) }
            changed.append((target, previous, existed, source))
            try FileManager.default.moveItem(at: source, to: target)
        }
    } catch {
        for (target, previous, existed, source) in changed.reversed() {
            if exists(target) { try FileManager.default.moveItem(at: target, to: source) }
            if existed && exists(previous) { try FileManager.default.moveItem(at: previous, to: target) }
        }
        throw error
    }
}
func publish(_ pending: URL, _ manifest: Message, shellOnly: Bool, brainOnly: Bool) throws {
    let lock = try FileLock(pending.deletingPathExtension().appendingPathExtension("lock"))
    defer { withExtendedLifetime(lock) {} }
    let previous = exists(pending) ? try readJSON(pending) : nil
    if let previous {
        guard previous["runtime"] as? String == manifest["runtime"] as? String,
              previous["bundle"] as? String == manifest["bundle"] as? String else { throw RuntimeFailure("pending update targets differ") }
        let old = try field(previous, "stage"), new = try field(manifest, "stage")
        if shellOnly && exists(child(old, "runtime/brain")) {
            try remove(child(new, "runtime/brain")); try FileManager.default.copyItem(at: child(old, "runtime/brain"), to: child(new, "runtime/brain"))
        }
        if brainOnly && exists(child(old, "bundle")) { try FileManager.default.copyItem(at: child(old, "bundle"), to: child(new, "bundle")) }
    }
    try atomicJSON(pending, manifest)
    if let previous, previous["stage"] as? String != manifest["stage"] as? String { try remove(field(previous, "stage")) }
}
func liveUpdate(_ manifest: inout Message) async throws -> Bool {
    let root = try home(manifest), endpoint = child(root, "backend/host.sock"), stage = child(try field(manifest, "stage"), "runtime")
    guard exists(endpoint), exists(child(stage, "HANDOFF.json")) else { return false }
    let runtime: URL
    if let existing = manifest["live_runtime"] as? String { runtime = URL(fileURLWithPath: existing) }
    else {
        let releases = child(root, "releases"); try mkdir(releases)
        runtime = child(releases, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let temporary = runtime.appendingPathExtension("new")
        try FileManager.default.copyItem(at: stage, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: runtime); manifest["live_runtime"] = runtime.path
    }
    do {
        _ = try await request(endpoint, ["op": "update", "runtime": runtime.path], timeout: 30)
        manifest["backend_applied"] = true; print("Backend updated live; existing pages remain alive."); return true
    } catch { manifest["deferred_reason"] = String(describing: error); print("Live update deferred: \(error)"); return false }
}
func refreshWatcher(_ pending: URL) throws {
    let pending = pending.resolvingSymlinksInPath()
    let lock = try FileLock(pending.deletingPathExtension().appendingPathExtension("lock"))
    defer { withExtendedLifetime(lock) {} }
    let pids = try command("/usr/sbin/lsof", ["-t", pending.deletingPathExtension().appendingPathExtension("watcher.lock").path])
    for value in Set(pids.split(whereSeparator: { $0.isWhitespace })) {
        guard let pid = Int32(value), pid != getpid() else { continue }
        // Match the native executable and this exact home before signalling the lock holder.
        let args = try command("/bin/ps", ["-p", String(pid), "-o", "args="]).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = child(pending.deletingLastPathComponent(), "apply-update").path + " " + pending.path + " --wait"
        if args == expected { kill(pid, SIGTERM); print("Retired previous pending-update watcher.") }
    }
}
func runUpdater(_ args: [String]) async throws {
    guard let first = args.first else { throw RuntimeFailure("usage: apply-update PENDING [--wait|--refresh-watcher]") }
    let pending = URL(fileURLWithPath: first); try mkdir(pending.deletingLastPathComponent())
    if args.contains("--refresh-watcher") { try refreshWatcher(pending); return }
    guard let watcher = try? FileLock(pending.deletingPathExtension().appendingPathExtension("watcher.lock"), nonblocking: true) else { return }
    defer { withExtendedLifetime(watcher) {} }
    while true {
        do {
            let lock = try FileLock(pending.deletingPathExtension().appendingPathExtension("lock"))
            defer { withExtendedLifetime(lock) {} }
            guard exists(pending) else { return }
            var manifest = try readJSON(pending)
            if try busy(manifest), manifest["backend_applied"] as? Bool != true,
               Date().timeIntervalSince1970 - (manifest["live_attempt_at"] as? Double ?? 0) >= 60 {
                manifest["live_attempt_at"] = Date().timeIntervalSince1970
                _ = try await liveUpdate(&manifest); try atomicJSON(pending, manifest)
            }
            if try !busy(manifest) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if try !busy(manifest) {
                    try activate(manifest)
                    let root = try home(manifest); try remove(child(root, "backend/active.json"))
                    for release in (try? FileManager.default.contentsOfDirectory(at: child(root, "releases"), includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])) ?? [] {
                        let name = release.lastPathComponent, values = try release.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                        if name.count == 32 && name.allSatisfy({ "0123456789abcdef".contains($0) }) && values.isDirectory == true && values.isSymbolicLink != true { try remove(release) }
                    }
                    try remove(pending); try remove(field(manifest, "stage"))
                    print("Staged Bowser update activated. Ready for next launch."); return
                }
            }
        }
        if !args.contains("--wait") { print("Update staged; it will activate after Bowser and saved apps quit."); return }
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }
}
