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
        SurfaceServices.shared.dragView = { id, select in
            let view = TabAppDragView(); view.webviewID = id; view.select = select; return view
        }
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
