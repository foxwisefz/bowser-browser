import WebKit

enum CookieAccess {
    static func target(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func matches(domain: String, host: String) -> Bool {
        let domain = domain.lowercased().hasPrefix(".") ? String(domain.dropFirst()).lowercased() : domain.lowercased()
        let host = host.lowercased()
        guard !domain.isEmpty, !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    @MainActor static func store(profile: String?, webview: UInt64) -> WKWebsiteDataStore? {
        if webview != 0 {
            guard let view = EngineView.live[webview], profile == nil || view.profileId == profile else { return nil }
            return view.webView.configuration.websiteDataStore
        }
        if let config = SiteAppConfiguration.current {
            guard profile == nil || profile == config.profile else { return nil }
            return EngineView.live.values.first?.webView.configuration.websiteDataStore
        }
        guard let profile, let owner = Profile.all.first(where: { $0.id == profile }) else { return nil }
        return owner.dataStore
    }
}
