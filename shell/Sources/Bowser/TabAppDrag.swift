import BowserSurfaceKit
import AppKit
import CryptoKit
import SwiftUI

/// Persistent site apps reuse Bowser’s executable, with their own macOS identity.
@MainActor
enum TabAppBundle {
    static func create(url: URL, profile: String, iconData: Data?, directory: URL,
                       bowser: URL, sign: Bool = true) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host else { throw CocoaError(.fileWriteInvalidFileName) }
        let identity = Data((profile + "\n" + url.absoluteString).utf8)
        let key = SHA256.hash(data: identity).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = host.replacingOccurrences(of: "/", with: "_")
        let bundle = directory.appendingPathComponent("\(name)-\(key).app", isDirectory: true)
        // Stable paths are essential: the Dock keeps a reference to this file.
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) {
            try upgrade(bundle: bundle, bowser: bowser, sign: sign)
            return bundle
        }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).app")
        let contents = staging.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/launch")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: bowser.appendingPathComponent("Contents/MacOS/Bowser"), to: executable)
        try copyStateLibrary(from: bowser, to: staging)
        let info: [String: Any] = [
            "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleIdentifier": "com.foxwiseai.bowser.site.\(key)",
            "CFBundleExecutable": "launch", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "2", "BowserAppVersion": 2,
            "BowserEngineBuild": try engineBuild(bowser),
            "BowserMainApp": bowser.path, "CFBundleIconFile": "SiteIcon.icns",
            "NSCameraUsageDescription": "Allow websites you approve to use your camera.",
            "NSMicrophoneUsageDescription": "Allow websites you approve to use your microphone.",
            "BowserSavedURL": url.absoluteString, "BowserProfile": profile,
        ]
        if let iconData {
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try iconData.write(to: resources.appendingPathComponent("SiteIcon.icns"))
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if sign { try signBundle(staging) }
        try FileManager.default.moveItem(at: staging, to: bundle)
        return bundle
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser Apps")
    }

    static func engineBuild(_ bowser: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: bowser.appendingPathComponent("Contents/MacOS/Bowser").path)
        return "\(attrs[.size] ?? 0)-\(attrs[.modificationDate] ?? "")"
    }

    static func upgrade(bundle: URL, bowser: URL, sign: Bool = true) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier.hasPrefix("com.foxwiseai.bowser.site."), info["BowserSavedURL"] is String else { return }
        let build = try engineBuild(bowser)
        let engineChanged = info["BowserAppVersion"] as? Int != 2 || info["BowserEngineBuild"] as? String != build
        let savedURL = (info["BowserSavedURL"] as? String).flatMap(URL.init(string:))
        let cached = savedURL.flatMap { cachedIcon(url: $0, profile: info["BowserProfile"] as? String ?? "default") }
        let iconHash = cached.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let iconChanged = iconHash != nil && info["BowserIconHash"] as? String != iconHash
        guard engineChanged || iconChanged else { return }
        // Updating an executing Mach-O can kill its process. Leave running
        // apps alone; they will be upgraded after they have quit.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { !$0.isTerminated }) else { return }
        if engineChanged {
            let target = bundle.appendingPathComponent("Contents/MacOS/launch")
            let temp = target.appendingPathExtension("new")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: bowser.appendingPathComponent("Contents/MacOS/Bowser"), to: temp)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            try copyStateLibrary(from: bowser, to: bundle)
            info["BowserAppVersion"] = 2
            info["CFBundleVersion"] = "2"
            info["BowserEngineBuild"] = build
            info["BowserMainApp"] = bowser.path
            info["NSCameraUsageDescription"] = "Allow websites you approve to use your camera."
            info["NSMicrophoneUsageDescription"] = "Allow websites you approve to use your microphone."
        }
        if iconChanged, let cached {
            let resources = bundle.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try cached.write(to: resources.appendingPathComponent("SiteIcon.icns"), options: .atomic)
            info["BowserIconHash"] = iconHash
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist, options: .atomic)
        if sign { try signBundle(bundle) }
    }

    static func upgradeSavedApps() {
        guard SiteAppConfiguration.current == nil else { return }
        let bundles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for bundle in bundles where bundle.pathExtension == "app" {
            do { try upgrade(bundle: bundle, bowser: Bundle.main.bundleURL) }
            catch { NSLog("Bowser: site app upgrade failed: %@", error.localizedDescription) }
        }
    }

    private static func copyStateLibrary(from browser: URL, to bundle: URL) throws {
        let relative = "Contents/Frameworks/libBowserSurfaceKit.dylib"
        let destination = bundle.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.copyItem(at: browser.appendingPathComponent(relative), to: temp)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: destination) }
    }

    private static func signBundle(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--preserve-metadata=entitlements", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
    }

    nonisolated static func iconKey(url: URL, profile: String) -> String {
        let origin = "\(url.scheme ?? "https")://\(url.host ?? "")" + (url.port.map { ":\($0)" } ?? "")
        return SHA256.hash(data: Data((profile + "\n" + origin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func cachedIcon(url: URL, profile: String) -> Data? {
        try? Data(contentsOf: BowserPaths.home.appendingPathComponent("app-icons-v2/" + iconKey(url: url, profile: profile) + ".icns"))
    }


}

