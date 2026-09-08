import AppKit

/// A small, validated native styling vocabulary shared with Chrome.set_theme.
/// Empty values restore the page-adaptive native appearance.
struct ShellTheme: Equatable {
    var colors: [String: String] = [:]
    var buttonStyle = "flat"
    var showNavigation = false
    var titleSize: CGFloat = 12.5
    var cornerRadius: CGFloat = 6
    var windowBorderWidth: CGFloat = 0
    var windowBorderStyle = "flat"

    static let native = ShellTheme()

    init() {}

    init?(json: [String: Any]) {
        self.init()
        for (key, value) in json {
            switch key {
            case "background", "foreground", "button_background", "button_foreground", "accent", "border", "window_border":
                guard let hex = value as? String,
                      hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { return nil }
                colors[key] = hex
            case "button_style":
                guard let style = value as? String, ["flat", "beveled"].contains(style) else { return nil }
                buttonStyle = style
            case "window_border_style":
                guard let style = value as? String, ["flat", "beveled"].contains(style) else { return nil }
                windowBorderStyle = style
            case "show_navigation":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                showNavigation = number.boolValue
            case "title_size", "corner_radius", "window_border_width":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                let n = number.doubleValue
                let range = key == "title_size" ? 9.0...16.0 : 0.0...12.0
                guard n.isFinite, range.contains(n) else { return nil }
                if key == "title_size" { titleSize = n }
                else if key == "window_border_width" { windowBorderWidth = n }
                else { cornerRadius = n }
            default: return nil
            }
        }
    }

    func color(_ key: String) -> NSColor? {
        guard let hex = colors[key], let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
