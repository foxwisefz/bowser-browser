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

struct ProfileCharacterPicker: View {
    let selected: ProfileCharacter?
    let choose: (ProfileCharacter) -> Void
    @State private var page: Int

    init(selected: ProfileCharacter?, choose: @escaping (ProfileCharacter) -> Void) {
        self.selected = selected
        self.choose = choose
        _page = State(initialValue: selected.flatMap { ProfileCharacter.allCases.firstIndex(of: $0) }.map { $0 / 6 } ?? 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Characters \(page * 6 + 1)–\(page * 6 + 6) of \(ProfileCharacter.allCases.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0)
                    .accessibilityLabel("Previous characters")
                Button { page += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(page == (ProfileCharacter.allCases.count - 1) / 6)
                    .accessibilityLabel("Next characters")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(ProfileCharacter.allCases.dropFirst(page * 6).prefix(6))) { character in
                    let active = selected == character
                    Button { choose(character) } label: {
                        VStack(spacing: 6) {
                            ProfileCharacterPortrait(character: character)
                            Text(character.title).font(.system(size: 12, weight: active ? .semibold : .medium))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(character.color.opacity(active ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(active ? character.color : Color.primary.opacity(0.08), lineWidth: active ? 2 : 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            if active {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(character.color)
                                    .padding(6)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(character.title)
                    .accessibilityValue(active ? "Selected" : "Not selected")
                    .help("Use \(character.title) as your profile character")
                }
            }
        }
        .onChange(of: selected) { _, value in
            if let value, let index = ProfileCharacter.allCases.firstIndex(of: value) { page = index / 6 }
        }
    }
}

/// A local draft submits as one structured event: names are never parsed as
/// colors or emoji. Server responses leave invalid drafts intact.
struct ProfileCreationForm: View {
    let node: [String: Any]
    let emit: (String, Any?) -> Void

    @State private var name = ""
    @State private var character: ProfileCharacter = .bowser
    @State private var tint = Color(nsColor: Profile.color(hex: ProfileCharacter.bowser.tint)!)
    @State private var submitting = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var responseID: Int { node["response_id"] as? Int ?? 0 }
    private var error: String? { node["error"] as? String }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your character")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Text("A fresh window with separate website logins and site data. Make it yours.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Profile name").font(.system(size: 12, weight: .semibold))
                TextField("Work, Personal, Side quests…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Profile name")
                    .onSubmit(create)
            }
            ProfileCharacterPicker(selected: character) { next in
                // Follow the character palette until the user customizes it.
                if SurfaceColorPickerHexBridge.hex(NSColor(tint)) == character.tint {
                    tint = next.color
                }
                character = next
            }
            HStack {
                ColorPicker("Window color", selection: $tint, supportsOpacity: false)
                    .font(.system(size: 12))
                Spacer()
                Text("Change it anytime").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .accessibilityLabel("Could not create profile: \(error)")
            }
            HStack {
                ProfileCharacterPortrait(character: character, size: 24)
                Text(trimmedName.isEmpty ? "Your next adventure" : trimmedName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button(submitting ? "Creating…" : "Create & Open", action: create)
                    .buttonStyle(.borderedProminent)
                    .tint(character.color)
                    .disabled(trimmedName.isEmpty || submitting)
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: responseID) { _, _ in
            submitting = false
            if node["created"] as? Bool == true { name = "" }
        }
    }

    private func create() {
        guard !trimmedName.isEmpty, !submitting else { return }
        submitting = true
        emit("new", ["name": trimmedName, "character": character.rawValue,
                     "tint": SurfaceColorPickerHexBridge.hex(NSColor(tint))])
    }
}
