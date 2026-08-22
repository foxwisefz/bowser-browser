import Foundation

/// Talks to the Bowser brain's XServer (BowserBrain.XServer, port 4808).
/// In the simulator, localhost is the host Mac. On a device, set the Mac's
/// LAN IP in Settings → the app reads `brainHost` from UserDefaults.
enum BrainClient {
    static var baseURL: URL {
        let host = UserDefaults.standard.string(forKey: "brainHost") ?? "localhost"
        return URL(string: "http://\(host):4808")!
    }

    /// Fetch a route's screen + data. `route` is "home", "@handle",
    /// "search/query" — mirrors XServer's paths.
    static func screen(route: String) async throws -> SDUIResponse {
        let url = baseURL.appendingPathComponent("x").appendingPathComponent(route)
        var request = URLRequest(url: url)
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
