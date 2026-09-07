import Foundation
import IconRendering
import Darwin

// No AppKit application, browser windows, sockets, or callbacks in this process.
// Input/output paths are created by the supervising Elixir job.
let args = CommandLine.arguments
if args.count != 4 && args.count != 5 { exit(64) }
do {
    let input = URL(fileURLWithPath: args[1])
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 4_000_000 else { exit(65) }
    let data = try Data(contentsOf: input)
    guard let png = IconRenderer.normalizedPNG(data) else { exit(65) }
    let appPNG: Data
    if args.count == 5 {
        let badgeURL = URL(fileURLWithPath: args[4])
        guard (try badgeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_500_000,
              let badged = IconRenderer.badgedPNG(png, badge: try Data(contentsOf: badgeURL)) else { exit(65) }
        appPNG = badged
    } else { appPNG = png }
    guard let icns = IconRenderer.icns(appPNG) else { exit(65) }
    try png.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    try icns.write(to: URL(fileURLWithPath: args[3]), options: .atomic)
} catch { exit(74) }
