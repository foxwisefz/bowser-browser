import AppKit
import SwiftUI

/// One color contract for SwiftUI surfaces and AppKit editors. Resolve at render
/// time in the view's appearance; never bake the current system mode into JSON.
enum SurfaceColorSpec {
    static let variants: Set<String> = ["light", "dark", "high_contrast_light", "high_contrast_dark"]
    static func valid(_ value: Any, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        if let string = value as? String {
            return string.range(of: "^(#[0-9a-fA-F]{6}|[a-z][a-z0-9_]{0,63})$", options: .regularExpression) != nil
        }
        guard let map = value as? [String: Any], map["light"] != nil, map["dark"] != nil,
              Set(map.keys).isSubset(of: variants) else { return false }
        return map.values.allSatisfy { valid($0, depth: depth + 1) }
    }
    static func validPalette(_ palette: [String: Any]) -> Bool {
        palette.count <= 64 && palette.allSatisfy { key, value in
            key.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil && valid(value)
        }
    }
    static func validStyle(_ style: [String: Any]) -> Bool {
        style.allSatisfy { key, value in
            if key == "palette" { return (value as? [String: Any]).map(validPalette) ?? false }
            return ["foreground", "background", "border", "accent"].contains(key) && valid(value)
        }
    }
    static func system(_ role: String) -> NSColor? {
        switch role {
        case "text": return .labelColor
        case "secondary_text": return .secondaryLabelColor
        case "surface": return .windowBackgroundColor
        case "editor_background": return .textBackgroundColor
        case "control_background": return .controlBackgroundColor
        case "separator": return .separatorColor
        case "accent": return .controlAccentColor
        case "selection": return .selectedTextBackgroundColor
        case "selected_text": return .selectedTextColor
        case "disabled_text": return .disabledControlTextColor
        case "error": return .systemRed
        default: return nil
        }
    }
    static func resolve(_ value: Any?, palette: [String: Any] = [:], dark: Bool, highContrast: Bool,
                        fallback: String = "text") -> NSColor {
        func find(_ value: Any, seen: Set<String>, depth: Int) -> NSColor? {
            guard depth < 16 else { return nil }
            if let name = value as? String {
                if let hex = Profile.color(hex: name) { return hex }
                if let custom = palette[name], !seen.contains(name) {
                    return find(custom, seen: seen.union([name]), depth: depth + 1)
                }
                return system(name)
            }
            guard let map = value as? [String: Any] else { return nil }
            let normal = dark ? "dark" : "light"
            guard let variant = (highContrast ? map["high_contrast_" + normal] : nil) ?? map[normal] else { return nil }
            return find(variant, seen: seen, depth: depth + 1)
        }
        let source = value.flatMap { find($0, seen: [], depth: 0) }
            ?? find(fallback, seen: [], depth: 0) ?? system(fallback) ?? .labelColor
        let name: NSAppearance.Name = highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        var resolved = source
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = source.usingColorSpace(.sRGB) ?? source
        }
        return resolved
    }
}

private struct SurfacePaletteKey: EnvironmentKey { static var defaultValue: [String: Any] { [:] } }
extension EnvironmentValues {
    var surfacePalette: [String: Any] {
        get { self[SurfacePaletteKey.self] }
        set { self[SurfacePaletteKey.self] = newValue }
    }
}
struct SurfaceColors: DynamicProperty {
    @Environment(\.surfacePalette) var palette
    @Environment(\.colorScheme) var scheme
    @Environment(\.colorSchemeContrast) var contrast
    func native(_ value: Any?, fallback: String = "text") -> NSColor {
        SurfaceColorSpec.resolve(value, palette: palette, dark: scheme == .dark,
                                 highContrast: contrast == .increased, fallback: fallback)
    }
    func color(_ value: Any?, fallback: String = "text") -> Color { Color(nsColor: native(value, fallback: fallback)) }
}

struct SurfacePaletteScope: ViewModifier {
    let palette: [String: Any]?
    @Environment(\.surfacePalette) private var inherited
    @ViewBuilder func body(content: Content) -> some View {
        if let palette, SurfaceColorSpec.validPalette(palette) {
            content.modifier(SurfacePaletteDefaults())
                .environment(\.surfacePalette, inherited.merging(palette) { _, replacement in replacement })
        } else { content }
    }
}
private struct SurfacePaletteDefaults: ViewModifier {
    var colors = SurfaceColors()
    func body(content: Content) -> some View {
        content.foregroundStyle(colors.color("text")).tint(colors.color("accent"))
    }
}

struct ModToolbarView: View {
    let bar: ModToolbar
    let webview: UInt64
    var colors = SurfaceColors()
    var body: some View {
        SurfaceTreeView(surfaceId: "toolbar:\(bar.id)", node: bar.view, eventWebview: webview)
            .padding(4)
            .foregroundStyle(colors.color(bar.style["foreground"], fallback: "text"))
            .tint(colors.color(bar.style["accent"], fallback: "accent"))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: bar.edge == "left" || bar.edge == "right" ? .topLeading : .leading)
            .background(colors.color(bar.style["background"], fallback: "surface"))
            .overlay(Rectangle().strokeBorder(bar.style["border"].map { colors.color($0, fallback: "separator") } ?? .clear, lineWidth: 1))
    }
}
