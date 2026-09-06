import Foundation
import IconRendering
import Darwin

// No AppKit application, browser windows, sockets, or callbacks in this process.
// Input/output paths are created by the supervising Elixir job.
let args = CommandLine.arguments
if args.count != 4 { exit(64) }
do {
    let input = URL(fileURLWithPath: args[1])
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 4_000_000 else { exit(65) }
    let data = try Data(contentsOf: input)
    guard let png = IconRenderer.normalizedPNG(data), let icns = IconRenderer.icns(png) else { exit(65) }
    try png.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    try icns.write(to: URL(fileURLWithPath: args[3]), options: .atomic)
} catch { exit(74) }
