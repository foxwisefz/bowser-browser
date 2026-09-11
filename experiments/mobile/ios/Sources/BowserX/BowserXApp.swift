import SwiftUI

/// BowserX (ADR 0011): a native iOS client whose screens are SDUI
/// declarations served by the Bowser brain. The mods you build on the Mac
/// become editable/new-able NATIVE apps here — this is the "X, your way,
/// on iOS" proof.
@main
struct BowserXApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    // The routes are the "apps" — each is a declaration the brain serves.
    // New app = new route/declaration; no App Store round-trip.
    private let routes: [(label: String, symbol: String, route: String)] = [
        ("Home", "house", "home"),
        ("Big", "rectangle.on.rectangle.angled", "home?view=gallery"),
        ("Search", "magnifyingglass", "search/ios")
    ]

    var body: some View {
        TabView {
            ForEach(routes, id: \.route) { r in
                NavigationStack {
                    FeedView(route: r.route)
                }
                .tabItem { Label(r.label, systemImage: r.symbol) }
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Point the app at a brain: localhost in the simulator, the Mac's LAN IP on
/// a device.
struct SettingsView: View {
    @AppStorage("brainHost") private var brainHost = "localhost"

    var body: some View {
        NavigationStack {
            Form {
                Section("Brain") {
                    TextField("Host", text: $brainHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Simulator: localhost · Device: your Mac's LAN IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Screens are SDUI declarations served by the Bowser brain (port 4808). Edit the declaration, this UI changes — no rebuild.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
