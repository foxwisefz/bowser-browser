import Foundation

/// The state dir shared with the brain: ~/.bowser, or BOWSER_HOME when set
/// (a dev brain+browser runs beside the installed one under ~/.bowser-dev).
/// The brain spawns the browser, so the env var reaches us from it.
enum BowserPaths {
    nonisolated static var home: URL {
        if let dir = ProcessInfo.processInfo.environment["BOWSER_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bowser", isDirectory: true)
    }
}
