import BowserSurfaceKit
import SwiftUI
struct ModToolbarView: View {
    let bar: ModToolbar
    let webview: UInt64
    var colors = SurfaceColors()
    var body: some View {
        LiveSurfaceTree(surfaceId: "toolbar:\(bar.id)", node: bar.view, eventWebview: webview, style: bar.style)
            .padding(4)
            .foregroundStyle(colors.color(bar.style["foreground"], fallback: "text"))
            .tint(colors.color(bar.style["accent"], fallback: "accent"))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: bar.edge == "left" || bar.edge == "right" ? .topLeading : .leading)
            .background(colors.color(bar.style["background"], fallback: "surface"))
            .overlay(Rectangle().strokeBorder(bar.style["border"].map { colors.color($0, fallback: "separator") } ?? .clear, lineWidth: 1))
    }
}
