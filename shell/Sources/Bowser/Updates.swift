import AppKit
import CryptoKit

struct UpdateRelease: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let minimumMacOS: Int
    let url: URL
    let bytes: Int64
    let sha256: String
    let expiresAt: Date

    static func verified(_ data: Data, publicKey: Data, currentBuild: String, osMajor: Int,
                         now: Date = Date()) throws -> Self? {
        struct Envelope: Decodable { let payload: Data; let signature: Data }
        guard data.count <= 16384 else { throw UpdateError.invalidRelease }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else { throw UpdateError.invalidRelease }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(Self.self, from: envelope.payload)
        guard let build = UInt64(release.build), let current = UInt64(currentBuild),
              release.version.count <= 64, !release.version.isEmpty,
              release.minimumMacOS >= 15, release.minimumMacOS <= osMajor,
              release.bytes > 0, release.bytes <= 1_073_741_824,
              release.url.scheme == "https", release.url.host == "bowser.app", release.url.port == nil,
              release.url.user == nil, release.url.password == nil,
              release.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              release.expiresAt > now else { throw UpdateError.invalidRelease }
        return build > current ? release : nil
    }
    func verifyFile(_ file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(bytes) else { throw UpdateError.invalidRelease }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw UpdateError.invalidRelease }
    }
}

enum UpdateError: Error { case invalidRelease, unavailable, commandFailed }

final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// All file/process work runs off the UI thread. Only a signed, hash-checked
/// image is mounted. The existing installer owns atomic publish and activation.
enum UpdateInstaller {
    static func run(_ executable: String, _ args: [String], allowFailure: Bool = false) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure { throw UpdateError.commandFailed }
    }
    static func stage(_ image: URL, release: UpdateRelease, home: URL, bundle: URL) throws {
        try release.verifyFile(image)
        let fm = FileManager.default, root = home.appendingPathComponent("updates")
        guard fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else { throw UpdateError.unavailable }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent("download-" + UUID().uuidString)
        let mount = fm.temporaryDirectory.appendingPathComponent("bowser-update-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        var published = false
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mount.path], allowFailure: true)
            try? fm.removeItem(at: mount)
            if !published { try? fm.removeItem(at: stage) }
        }
        try run("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path])
        let app = mount.appendingPathComponent("Bowser.app"), runtime = app.appendingPathComponent("Contents/Resources/runtime")
        guard let installed = Bundle(url: app), installed.bundleIdentifier == "com.foxwiseai.bowser",
              installed.infoDictionary?["CFBundleVersion"] as? String == release.build,
              installed.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.invalidRelease }
        for file in ["bin/bowser", "bin/apply-update", "bin/backend-host", "brain/bin/bowser_brain"] {
            guard fm.isExecutableFile(atPath: runtime.appendingPathComponent(file).path) else { throw UpdateError.invalidRelease }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/bin/ditto", [app.path, stage.appendingPathComponent("bundle").path])
        try run("/usr/bin/ditto", [runtime.path, stage.appendingPathComponent("runtime").path])
        // Invoke the helper under its dispatch name; watcher uses apply-update.
        let helper = stage.appendingPathComponent("BowserRuntimeTool")
        try fm.copyItem(at: runtime.appendingPathComponent("bin/apply-update"), to: helper)
        let pending = root.appendingPathComponent("pending.json")
        try run(helper.path, ["publish", pending.path, stage.path, home.appendingPathComponent("app").path, bundle.path, "0", "0"])
        published = true
        let next = root.appendingPathComponent("apply-update.new"), watcher = root.appendingPathComponent("apply-update")
        try? fm.removeItem(at: next)
        try fm.copyItem(at: helper, to: next)
        // rename(2) atomically replaces an existing watcher executable.
        guard rename(next.path, watcher.path) == 0 else { throw UpdateError.commandFailed }
        let agents = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("com.foxwiseai.bowser.pending-update.plist")
        try run(helper.path, ["watcher-plist", plist.path, root.path])
        try run(watcher.path, [pending.path, "--refresh-watcher"])
        let domain = "gui/\(getuid())", label = domain + "/com.foxwiseai.bowser.pending-update"
        try run("/bin/launchctl", ["bootout", label], allowFailure: true)
        try run("/bin/launchctl", ["bootstrap", domain, plist.path])
        try run("/bin/launchctl", ["kickstart", label])
    }
    static func download(_ release: UpdateRelease) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: UpdateDownloadDelegate(limit: release.bytes), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: release.url); request.timeoutInterval = 300
        let (temporary, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("bowser-" + UUID().uuidString + ".dmg")
        try FileManager.default.moveItem(at: temporary, to: image)
        do { try release.verifyFile(image); return image }
        catch { try? FileManager.default.removeItem(at: image); throw error }
    }
}

@MainActor
final class AppUpdates: NSObject {
    static let shared = AppUpdates()
    private var busy = false
    func start() {
        guard SiteAppConfiguration.current == nil,
              Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateCheck") > 86400 else { return }
        Task { await check(manual: false) }
    }
    @objc func checkForUpdates(_ sender: Any? = nil) { Task { await check(manual: true) } }
    private func message(_ text: String) { let alert = NSAlert(); alert.messageText = text; alert.runModal() }
    func check(manual: Bool) async {
        guard !busy else { if manual { message("An update check is already in progress.") }; return }
        guard let encoded = Bundle.main.infoDictionary?["BowserUpdatePublicKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            if manual { message("Updates are not available for this build yet.") }; return
        }
        busy = true; defer { busy = false }
        var requestedDownload = false
        do {
            var request = URLRequest(url: URL(string: "https://bowser.app/updates/stable.json")!); request.timeoutInterval = 20
            let (data, response) = try await PrivateHTTP.send(request)
            guard response.statusCode == 200 else { throw UpdateError.unavailable }
            let release = try UpdateRelease.verified(data, publicKey: key, currentBuild: build,
                osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            guard let release else { if manual { message("You’re up to date.") }; return }
            let alert = NSAlert(); alert.messageText = "Bowser \(release.version) is available"
            alert.informativeText = "Download now? The update will activate after Bowser and its saved apps quit."
            alert.addButton(withTitle: "Download Update"); alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            requestedDownload = true
            let home = BowserPaths.home, bundle = Bundle.main.bundleURL
            try await Task.detached {
                let image = try await UpdateInstaller.download(release)
                defer { try? FileManager.default.removeItem(at: image) }
                try UpdateInstaller.stage(image, release: release, home: home, bundle: bundle)
            }.value
            message("Update ready. It will activate after Bowser and its saved apps quit.")
        } catch { if manual || requestedDownload { message("Couldn’t prepare the update. Please try again later.") } }
    }
}
