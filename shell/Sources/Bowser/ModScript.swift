import WebKit
import JavaScriptCore

/// The shell owns scope and execution-world selection; source is never a host filter.
struct ModScript: Equatable, ExpressibleByStringLiteral {
    var source: String
    var world: String = "isolated"
    var host: String? = nil
    var origin: String? = nil

    init(stringLiteral value: String) { source = value }
    init(source: String, world: String = "isolated", host: String? = nil, origin: String? = nil) {
        self.source = source; self.world = world; self.host = host; self.origin = origin
    }
    @MainActor static let isolatedWorld = WKContentWorld.world(name: "bowser.mods")
    @MainActor static let dispatchWorld = WKContentWorld.world(name: "bowser.dispatch")
    @MainActor var contentWorld: WKContentWorld { world == "page" ? .page : Self.isolatedWorld }
    var wire: [String: Any] {
        var result: [String: Any] = ["source": source, "world": world]
        result["host"] = host; result["origin"] = origin
        return result
    }
    static func parseList(_ value: Any?) -> [ModScript]? {
        guard let value else { return nil }
        guard let values = value as? [Any] else { return [] }
        var result: [ModScript] = []
        for value in values {
            if let source = value as? String { result.append(ModScript(source: source)); continue }
            guard let map = value as? [String: Any], let source = map["source"] as? String,
                  let world = map["world"] as? String, ["isolated", "page"].contains(world),
                  map["host"] == nil || map["host"] is String,
                  map["origin"] == nil || map["origin"] is String else { return [] }
            result.append(ModScript(source: source, world: world, host: map["host"] as? String, origin: map["origin"] as? String))
        }
        return result
    }
    func matches(_ url: URL) -> Bool {
        if host == nil && origin == nil { return ["https", "http", "file", "about"].contains(url.scheme?.lowercased() ?? "") }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let actual = url.host?.lowercased() else { return false }
        if let host {
            let host = host.lowercased()
            guard !host.isEmpty, actual == host || actual.hasSuffix("." + host) else { return false }
        }
        if let origin {
            guard let target = URL(string: origin), target.scheme == url.scheme, target.host?.lowercased() == actual,
                  (target.port ?? (target.scheme == "https" ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80)) else { return false }
        }
        return true
    }
    static func declaredWorld(_ source: String) -> String? {
        var lines = source.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression).components(separatedBy: .newlines)
        if lines.first?.hasPrefix("// bowser-profile: ") == true {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        guard let first = lines.first, first.hasPrefix("// bowser-world: ") else { return "isolated" }
        let value = String(first.dropFirst("// bowser-world: ".count)).trimmingCharacters(in: .whitespaces)
        return ["isolated", "page"].contains(value) ? value : nil
    }

    /// Parse as a function body without executing it. A valid body cannot close
    /// the nested function and escape the earlier navigation check. WebKit's
    /// native executor avoids page CSP eval restrictions.
    @MainActor private static var compiledBodies: [String: String] = [:]

    @MainActor static func guardedSource(_ source: String) -> String? {
        if let compiled = compiledBodies[source] { return compiled }
        guard let context = JSContext() else { return nil }
        _ = context.objectForKeyedSubscript("Function").call(withArguments: [source])
        guard context.exception == nil else { return nil }
        let compiled = "if (location.href !== expectedURL) return false;\n(function(){\n" + source + "\n})();\nreturn true;"
        if compiledBodies.count >= 64 { compiledBodies.removeAll() }
        compiledBodies[source] = compiled
        return compiled
    }
    static let ready = """
    window.webkit.messageHandlers.bowserScriptsReady.postMessage(location.href);
    """
}
