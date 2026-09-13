import AppKit
import SwiftUI
import BowserSurfaceKit

@MainActor enum SurfaceHostServices {
    private static var configured = false
    static func configure() {
        guard !configured else { return }; configured = true
        SurfaceServices.shared.emit = { message in
            if message["event"] as? String == "surface_dismiss", let id = message["surface"] as? String {
                SurfaceManager.shared.dismiss(id: id)
            } else { BrainBridge.shared.send(message) }
        }
        SurfaceServices.shared.tabSnapshot = { id in
            guard let tab = EngineView.live[id] else { return nil }
            return SurfaceTabSnapshot(icon: tab.faviconPath.flatMap { NSImage(contentsOfFile: $0) },
                canExport: ["http", "https"].contains(tab.webView.url?.scheme ?? ""))
        }
        SurfaceServices.shared.closeTab = { id in
            guard let host = BrowserWindowController.host(of: id) else { return false }
            host.closeTab(id: id); return true
        }
        SurfaceServices.shared.canMoveTab = { id, target in
            guard id != target, let host = BrowserWindowController.host(of: id) else { return false }
            return host === BrowserWindowController.host(of: target)
        }
        SurfaceServices.shared.moveTab = { id, target, after in
            guard SurfaceServices.shared.canMoveTab(id, target) else { return false }
            return BrowserWindowController.host(of: id)?.moveTab(id: id, relativeTo: target, after: after) == true
        }
        SurfaceServices.shared.exportTab = { id in
            guard let tab = EngineView.live[id], let url = tab.webView.url else { throw CocoaError(.fileNoSuchFile) }
            let bowser = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Bowser.app")
            return try TabAppBundle.create(url: url, profile: tab.profileId, iconData: tab.appIconData,
                directory: TabAppBundle.directory, bowser: bowser)
        }
        SurfaceServices.shared.edgeDragging = { SurfaceManager.shared.setEdgeDragging("edge_dock", $0) }
        SurfaceServices.shared.portrait = { name, size in
            guard let character = ProfileCharacter(rawValue: name) else { return AnyView(EmptyView()) }
            return AnyView(ProfileCharacterPortrait(character: character, size: size))
        }
        profiles(Profile.all)
    }
    static func profiles(_ profiles: [Profile]) {
        SurfaceServices.shared.profiles = profiles.map {
            SurfaceProfile(id: $0.id, name: $0.name, tint: $0.tint, icon: $0.icon, avatar: $0.character)
        }
    }
}
