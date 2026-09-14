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
              release.url.scheme == "https", release.url.host == "assets.bowser.app", release.url.port == nil,
              release.url.user == nil, release.url.password == nil,
              release.url.absoluteString == "https://assets.bowser.app/releases/\(release.build)/Bowser.dmg",
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
    /// Publishing does not load code. Each running host independently checks
    /// Team ID, ABI, dependencies and its module budget before swapping views.
    static func publishModules(from app: URL, home: URL,
                               verify: (URL) throws -> Void = { try run("/usr/bin/codesign", ["--verify", "--strict", $0.path]) }) throws {
        let fm = FileManager.default
        for (name, kind, identifier) in [
            ("SurfaceRenderer", "surfaces", "com.foxwiseai.bowser.surfaces"),
            ("CommandToolbar", "command-toolbar", "com.foxwiseai.bowser.command-toolbar")
        ] {
            let source = app.appendingPathComponent("Contents/Resources/\(name).bundle")
            let info = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
            guard let metadata = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  metadata["CFBundleIdentifier"] as? String == identifier,
                  let build = metadata["CFBundleVersion"] as? String,
                  build.count == 32, build.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw UpdateError.invalidRelease }
            try verify(source)
            let root = home.appendingPathComponent("native-modules/" + kind)
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = root.appendingPathComponent(build + ".bundle")
            if !fm.fileExists(atPath: target.path) {
                let temporary = root.appendingPathComponent("stage-" + UUID().uuidString)
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: source, to: temporary)
                try verify(temporary)
                try fm.moveItem(at: temporary, to: target)
            } else {
                try verify(target)
            }
            try Data((build + "\n").utf8).write(to: root.appendingPathComponent("current"), options: .atomic)
        }
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
        try publishModules(from: stage.appendingPathComponent("bundle"), home: home)
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
    private var timer: Timer?
    func start() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task { @MainActor in AppUpdates.shared.start() }
            }
        }
        guard SiteAppConfiguration.current == nil,
              Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateCheck") > 86400 else { return }
        Task { await check(manual: false) }
    }
    nonisolated static func latestBuild(_ installed: String, _ prepared: String?) -> String {
        guard let prepared, let value = UInt64(prepared), value > (UInt64(installed) ?? 0) else { return installed }
        return prepared
    }
    @objc func checkForUpdates(_ sender: Any? = nil) { Task { await check(manual: true) } }
    private func message(_ text: String) { NativeUIHost.alert("message", ["text": text]).runModal() }
    func check(manual: Bool) async {
        guard !busy else { if manual { message("An update check is already in progress.") }; return }
        guard let encoded = Bundle.main.infoDictionary?["BowserUpdatePublicKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            if manual { message("Updates are not available for this build yet.") }; return
        }
        busy = true; defer { busy = false }
        do {
            var request = URLRequest(url: URL(string: "https://assets.bowser.app/updates/stable.json")!); request.timeoutInterval = 20
            let (data, response) = try await PrivateHTTP.send(request)
            guard response.statusCode == 200 else { throw UpdateError.unavailable }
            let release = try UpdateRelease.verified(data, publicKey: key, currentBuild: Self.latestBuild(build, UserDefaults.standard.string(forKey: "preparedUpdateBuild")),
                osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            guard let release else {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                if manual {
                    let prepared = Self.latestBuild(build, UserDefaults.standard.string(forKey: "preparedUpdateBuild"))
                    message(prepared == build ? "You’re up to date." : "The latest update is already prepared. Compatible components apply automatically; remaining changes wait for a normal quit.")
                }
                return
            }
            let home = BowserPaths.home, bundle = Bundle.main.bundleURL
            try await Task.detached {
                let image = try await UpdateInstaller.download(release)
                defer { try? FileManager.default.removeItem(at: image) }
                try UpdateInstaller.stage(image, release: release, home: home, bundle: bundle)
            }.value
            UserDefaults.standard.set(release.build, forKey: "preparedUpdateBuild")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            if manual { message("Update prepared. Compatible components apply automatically; anything requiring a restart waits until Bowser and its saved apps quit.") }
        } catch { if manual { message("Couldn’t prepare the update. Please try again later.") } }
    }
}
