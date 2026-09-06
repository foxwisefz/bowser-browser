import AppKit
import SwiftUI

/// Stable on-disk identifiers; artwork is bundled, never fetched at runtime.
enum ProfileCharacter: String, CaseIterable, Identifiable {
    case mario, luigi, peach, yoshi, toad, bowser
    case wario, waluigi, daisy, donkeyKong = "donkey-kong", diddyKong = "diddy-kong", rosalina
    case captainToad = "captain-toad", toadette, birdo, bowserJr = "bowser-jr", kamek, shyGuy = "shy-guy"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bowserJr: "Bowser Jr."
        default: rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
    var tint: String {
        switch self {
        case .mario: "#e5484d"
        case .luigi: "#30a46c"
        case .peach: "#d6409f"
        case .yoshi: "#76a832"
        case .toad: "#3e63dd"
        case .bowser: "#f76b15"
        case .wario: "#b18bde"
        case .waluigi: "#8e4ec6"
        case .daisy: "#e9a23b"
        case .donkeyKong: "#ac7046"
        case .diddyKong: "#e5484d"
        case .rosalina: "#12a594"
        case .captainToad: "#c99a32"
        case .toadette: "#d6409f"
        case .birdo: "#c64aaf"
        case .bowserJr: "#76a832"
        case .kamek: "#3e63dd"
        case .shyGuy: "#e5484d"
        }
    }

    /// Six portraits per supplied sheet, in reading order. Crop only at
    /// load time so the user's original pixels and alpha stay intact.
    var sprite: (sheet: String, rect: CGRect) {
        if self == .bowser {
            return ("friendly-bowser", CGRect(x: 409, y: 206, width: 201, height: 203))
        }
        let index = Self.allCases.firstIndex(of: self)!
        let columns = [(x: 0, width: 201), (x: 204, width: 202), (x: 409, width: 201)]
        let column = columns[index % 3]
        // These gutters exclude the divider lines on the adventurers sheet.
        return (["originals", "friends", "adventurers"][index / 6],
                CGRect(x: column.x, y: index % 6 < 3 ? 0 : 206, width: column.width, height: 203))
    }

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
        let installed = Bundle.main.resourceURL?
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
