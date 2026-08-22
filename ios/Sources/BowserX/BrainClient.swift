import Foundation

/// Talks to the Bowser brain's XServer (BowserBrain.XServer, port 4808).
/// In the simulator, localhost is the host Mac. On a device, set the Mac's
/// LAN IP in Settings → the app reads `brainHost` from UserDefaults.
enum BrainClient {
    static var baseURL: URL {
        let host = UserDefaults.standard.string(forKey: "brainHost") ?? "localhost"
        return URL(string: "http://\(host):4808")!
    }

    /// Fetch a route's screen + data. `want` controls scroll depth — the
    /// feed raises it as the reader nears the bottom (infinite scroll).
    static func screen(route: String, want: Int = 15) async throws -> SDUIResponse {
        // A route may carry its own query (e.g. "home?view=gallery"); split
        // it off, then merge in `want`.
        let parts = route.split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts[0]
        var components = URLComponents(
            url: baseURL.appendingPathComponent("x").appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        var items = [URLQueryItem(name: "want", value: String(want))]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                items.append(URLQueryItem(name: String(kv[0]), value: kv.count > 1 ? String(kv[1]) : ""))
            }
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BrainError.badStatus(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(SDUIResponse.self, from: data)
    }
}

enum BrainError: LocalizedError {
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            return "Brain returned \(code): \(body.prefix(140))"
        }
    }
}
