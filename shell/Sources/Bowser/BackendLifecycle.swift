import AppKit

/// The installed app bootstraps its runtime; dev shells keep using their dev brain.
@MainActor
final class BackendLifecycle {
    static let shared = BackendLifecycle()
    private var startup: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var isStarting = false
    private var launcher: Process?
    private(set) var isQuitting = false
    var quitAcknowledged = false

    static func helper(home: URL = BowserPaths.home,
                       bundledRuntime: URL? = Bundle.main.resourceURL?.appendingPathComponent("runtime")) -> URL? {
        // A distribution bundle carries a matching runtime. Development installs
        // retain the external layout; no runtime is copied into user state at launch.
        let candidates = [bundledRuntime, home.appendingPathComponent("app")].compactMap { $0 }
        return candidates.first { runtime in
            FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("bin/bowser").path) &&
            FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("brain/bin/bowser_brain").path)
        }?.appendingPathComponent("bin/bowser")
    }

    func start() {
        guard SiteAppConfiguration.current == nil, !isStarting, !isQuitting else { return }
        isStarting = true
        if monitor == nil {
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !isQuitting, !Task.isCancelled else { return }
                    if !BrainBridge.shared.isConnected { start() }
                }
            }
        }
        startup = Task { [weak self] in
            guard let self else { return }
            defer { isStarting = false }
            // A supervising brain may already be reconnecting to this shell.
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, !isQuitting, !BrainBridge.shared.isConnected else { return }
            guard let helper = Self.helper() else {
                if Bundle.main.bundleIdentifier == "com.foxwiseai.bowser" { showStartupFailure() }
                return
            }
            do {
                launcher = try launch(helper, action: "start-brain")
                for _ in 0..<150 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, !isQuitting else { return }
                    if BrainBridge.shared.isConnected { return }
                    if let launcher, !launcher.isRunning, launcher.terminationStatus != 0 { break }
                }
                showStartupFailure()
            } catch {
                showStartupFailure()
            }
        }
    }

    private func launch(_ helper: URL, action: String) throws -> Process {
        let process = Process()
        process.executableURL = helper
        process.arguments = [action]
        var environment = ProcessInfo.processInfo.environment
        environment["BOWSER_HOME"] = BowserPaths.home.path
        environment["BOWSER_APP_DIR"] = helper.deletingLastPathComponent().deletingLastPathComponent().path
        environment["BOWSER_BUNDLE_PATH"] = Bundle.main.bundleURL.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func showStartupFailure() {
        guard !isQuitting else { return }
        let alert = NSAlert()
        alert.messageText = "Bowser couldn’t start its backend"
        alert.informativeText = "Tabs and mods need the backend. Details are in \(BowserPaths.home.appendingPathComponent("brain.log").path)."
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit Bowser")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { [weak self] in
                await Task.yield()
                self?.start()
            }
        }
        else { NSApp.terminate(nil) }
    }

    func quit() -> NSApplication.TerminateReply {
        guard SiteAppConfiguration.current == nil else { return .terminateNow }
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        startup?.cancel()
        monitor?.cancel()
        Task {
            // Let an in-flight launcher finish so it cannot start a brain after quit.
            while launcher?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if BrainBridge.shared.isConnected {
                BrainBridge.shared.send(["op": "app_quit"])
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if quitAcknowledged && !BrainBridge.shared.isConnected {
                        NSApp.reply(toApplicationShouldTerminate: true)
                        return
                    }
                }
            }
            // Handles a startup failure or an older backend without the handshake.
            if let helper = Self.helper(), let stop = try? launch(helper, action: "stop-brain") {
                while stop.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
