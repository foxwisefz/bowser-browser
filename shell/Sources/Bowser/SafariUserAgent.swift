import Foundation

/// Safari and WKWebView share the system WebKit. Resolve the browser version
/// once per launch so an OS/Safari update cannot leave us advertising Safari 18.
enum SafariUserAgent {
    static let current: String = {
        let paths = [
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist",
            "/Applications/Safari.app/Contents/Info.plist",
            "/System/Applications/Safari.app/Contents/Info.plist"
        ]
        let installed = paths.lazy.compactMap { path -> String? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = info["CFBundleShortVersionString"] as? String else { return nil }
            return safariVersion(version)
        }.first
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let fallback = os.majorVersion >= 26 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion + 3).0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/\(installed ?? fallback) Safari/605.1.15"
    }()

    static func safariVersion(_ value: String) -> String? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), major > 0 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }
}
