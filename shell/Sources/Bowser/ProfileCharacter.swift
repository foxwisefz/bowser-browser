import BowserSurfaceKit

import AppKit
import SwiftUI

/// Stable on-disk identifiers; artwork is bundled, never fetched at runtime.
extension ProfileCharacter {
    @MainActor var color: Color { Color(nsColor: Profile.color(hex: tint)!) }

    @MainActor private static var images: [ProfileCharacter: NSImage] = [:]
    @MainActor private static var sheets: [String: CGImage] = [:]

    @MainActor var image: NSImage? {
        if let cached = Self.images[self] { return cached }
        let (sheet, rect) = sprite
        guard let atlas = Self.sheets[sheet] ?? Self.loadSheet(sheet),
              let crop = atlas.cropping(to: rect) else { return nil }
        let image = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
        Self.images[self] = image
        return image
    }

    @MainActor private static func loadSheet(_ sheet: String) -> CGImage? {
        // Installed app resources first; SwiftPM's bundle for dev and tests.
        let resourceURL = SiteAppConfiguration.current?.mainApp.appendingPathComponent("Contents/Resources")
            ?? Bundle.main.resourceURL
        let installed = resourceURL?
            .appendingPathComponent("ProfileCharacters/\(sheet).png")
        let url: URL?
        if Bundle.main.bundleURL.pathExtension == "app" {
            // A missing installed image should use the UI fallback, not touch
            // SwiftPM's accessor (which can fatalError outside a checkout).
            url = installed
        } else {
            url = Bundle.module.url(forResource: sheet, withExtension: "png", subdirectory: "ProfileCharacters")
        }
        guard let url, let source = NSImage(contentsOf: url),
              let decoded = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let image = sheet == "friendly-bowser" ? Self.cleanCutout(decoded) : decoded
        Self.sheets[sheet] = image
        return image
    }

    /// The supplied friendly sheet has a translucent background-removal
    /// shadow. Its nearly opaque neutral pixels survive an alpha-only
    /// cutoff, so discard that matte too while retaining the navy outline.
    @MainActor private static func cleanCutout(_ image: CGImage) -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let alpha = data[offset + 3]
            let high = max(data[offset], max(data[offset + 1], data[offset + 2]))
            let low = min(data[offset], min(data[offset + 1], data[offset + 2]))
            let neutralMatte = alpha < 255 && high <= 60 && high - low <= 8
            if alpha < 200 || neutralMatte {
                for channel in 0..<4 { data[offset + channel] = 0 }
            }
        }
        return context.makeImage() ?? image
    }
}

struct ProfileCharacterPortrait: View {
    let character: ProfileCharacter
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let image = character.image {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
