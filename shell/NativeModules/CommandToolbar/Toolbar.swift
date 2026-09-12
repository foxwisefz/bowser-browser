import AppKit
import SwiftUI

// ABI 1: bounded UTF-8 JSON snapshots, generation-tagged copied UTF-8 events,
// and one retained NSView pointer. No WebKit references or Swift values cross.
public typealias ToolbarEvent = @convention(c) @Sendable (UInt64, UnsafePointer<CChar>) -> Void
struct ToolbarButton: Decodable, Identifiable { let id: String; let title: String; let symbol: String? }
struct ToolbarSnapshot: Decodable {
    let revealed: Bool
    let tint: [Double]?
    let colors: [String: String]
    let buttonStyle: String
    let cornerRadius: Double
    let showNavigation: Bool
    let buttons: [ToolbarButton]
}
struct ToolbarTheme {
    var colors: [String: String] = [:]
    var buttonStyle = "flat"
    var cornerRadius: CGFloat = 6
    var showNavigation = false
    func color(_ key: String) -> NSColor? {
        guard let hex = colors[key], hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
    }
}
@MainActor final class ToolbarModel: ObservableObject {
    @Published var revealed = false
    var theme = ToolbarTheme()
    var tint: NSColor?
    var buttons: [ToolbarButton] = []
    func apply(_ data: Data) -> Bool {
        guard let value = try? JSONDecoder().decode(ToolbarSnapshot.self, from: data),
              value.buttons.count <= 128, value.cornerRadius.isFinite,
              (0...12).contains(value.cornerRadius) else { return false }
        objectWillChange.send()
        theme = ToolbarTheme(colors: value.colors, buttonStyle: value.buttonStyle, cornerRadius: value.cornerRadius, showNavigation: value.showNavigation)
        if let c = value.tint, c.count == 4, c.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            tint = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        } else { tint = nil }
        buttons = value.buttons; revealed = value.revealed
        return true
    }
}
@MainActor final class ToolbarView: NSHostingView<CommandToolbar> {
    let model: ToolbarModel
    init(model: ToolbarModel, generation: UInt64, event: @escaping ToolbarEvent) {
        self.model = model
        let emit: (String) -> Void = { text in text.withCString { event(generation, $0) } }
        super.init(rootView: CommandToolbar(model: model, openBar: { emit("command") }, goBack: { emit("back") }, goForward: { emit("forward") }, reload: { emit("reload") }, modClick: { emit("mod:" + $0) }, onHoverChanged: { emit($0 ? "hover:1" : "hover:0") }))
    }
    required init(rootView: CommandToolbar) { fatalError("use module_create") }
    required init?(coder: NSCoder) { fatalError("use module_create") }
}
@_cdecl("bowser_toolbar_abi") public func toolbarABI() -> Int32 { 1 }
@_cdecl("bowser_toolbar_create") public func toolbarCreate(_ bytes: UnsafePointer<UInt8>, _ count: Int32, _ generation: UInt64, _ event: @escaping ToolbarEvent) -> UnsafeMutableRawPointer? {
    guard count > 0 && count <= 65536 else { return nil }
    let data = Data(bytes: bytes, count: Int(count))
    let address: UInt? = MainActor.assumeIsolated {
        let model = ToolbarModel()
        guard model.apply(data) else { return nil }
        return UInt(bitPattern: Unmanaged.passRetained(ToolbarView(model: model, generation: generation, event: event)).toOpaque())
    }
    return address.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
}
@_cdecl("bowser_toolbar_update") public func toolbarUpdate(_ pointer: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>, _ count: Int32) -> Int32 {
    guard count > 0 && count <= 65536 else { return 0 }
    let address = UInt(bitPattern: pointer), data = Data(bytes: bytes, count: Int(count))
    return MainActor.assumeIsolated { Unmanaged<ToolbarView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().model.apply(data) ? 1 : 0 }
}
@_cdecl("bowser_toolbar_destroy") public func toolbarDestroy(_ pointer: UnsafeMutableRawPointer) {
    let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated {
        let object = Unmanaged<ToolbarView>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!)
        object.takeUnretainedValue().removeFromSuperview(); object.release()
    }
}
struct CommandToolbar: View {
    @ObservedObject var model: ToolbarModel
    private var theme: ToolbarTheme { model.theme }
    /// The window's profile tint — painted on the ⌘K keycap only (the
    /// owner's call: not the whole bar, not the command palette).
    private var tint: Color? { model.tint.map(Color.init(nsColor:)) }
    let openBar: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let reload: () -> Void
    let modClick: (String) -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: openBar) {
                // Keycap-style badge: outlined, rounded face, like a
                // keyboard shortcut printed on the chrome.
                Text("⌘+K")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(theme.color("button_foreground").map { AnyShapeStyle(Color(nsColor: $0)) }
                        ?? (tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.95))))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .fill(theme.color("button_background").map { Color(nsColor: $0) }
                                  ?? tint ?? Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(
                                theme.color("accent").map { Color(nsColor: $0) }
                                    ?? Color(red: 0.83, green: 0.65, blue: 0.13).opacity(0.95),
                                lineWidth: 1.2
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Command bar (⌘K)")
            .accessibilityIdentifier("command")
            // Revealed together with the window lights, same grace/fade.
            if model.revealed || theme.showNavigation {
                clusterButton("chevron.left", action: goBack)
                clusterButton("chevron.right", action: goForward)
                clusterButton("arrow.clockwise", action: reload)
                    .help("Reload this tab (⌘R)")
                ForEach(model.buttons, id: \.id) { button in
                    clusterButton(button.symbol ?? "puzzlepiece.extension") {
                        modClick(button.id)
                    }
                    .help(button.title)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: model.revealed)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { onHoverChanged($0) }
    }

    private func clusterButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("button_foreground").map { Color(nsColor: $0) } ?? .secondary)
                .frame(width: theme.buttonStyle == "beveled" ? 28 : 20,
                       height: theme.buttonStyle == "beveled" ? 22 : 20)
                .background {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.color("button_background").map { Color(nsColor: $0) } ?? .clear)
                }
                .overlay {
                    if theme.buttonStyle == "beveled" {
                        RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(LinearGradient(colors: [.white, Color(nsColor: theme.color("border") ?? .darkGray)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
