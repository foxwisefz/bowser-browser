import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Fit the supplied artwork, retaining its alpha and removing empty margins.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let scan = CGContext(data: nil, width: decoded.width, height: decoded.height,
                           bitsPerComponent: 8, bytesPerRow: decoded.width * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let pixels = scan.data?.assumingMemoryBound(to: UInt8.self) else {
    fatalError("Cannot read the application artwork")
}
scan.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
var left = decoded.width, top = decoded.height, right = 0, bottom = 0
for y in 0..<decoded.height {
    for x in 0..<decoded.width where pixels[(y * decoded.width + x) * 4 + 3] > 10 {
        left = min(left, x); top = min(top, y)
        right = max(right, x + 1); bottom = max(bottom, y + 1)
    }
}
guard left < right, top < bottom else { fatalError("Application artwork is empty") }
// Ignore near-invisible cutout speckles when measuring, without altering
// any pixels inside the portrait; keep two source pixels around its edges.
let bounds = CGRect(x: max(0, left - 2), y: max(0, top - 2),
                    width: min(decoded.width, right + 2) - max(0, left - 2),
                    height: min(decoded.height, bottom + 2) - max(0, top - 2))
guard let artwork = decoded.cropping(to: bounds) else { fatalError("Cannot fit application artwork") }

let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"),
             (32, "icon_32x32"), (64, "icon_32x32@2x"),
             (128, "icon_128x128"), (256, "icon_128x128@2x"),
             (256, "icon_256x256"), (512, "icon_256x256@2x"),
             (512, "icon_512x512"), (1024, "icon_512x512@2x")]

for (size, name) in sizes {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot allocate icon canvas")
    }
    context.interpolationQuality = .high
    let scale = Double(size) * 0.88 / Double(max(artwork.width, artwork.height))
    let height = (Double(artwork.height) * scale).rounded()
    let width = (Double(artwork.width) * scale).rounded()
    context.draw(artwork, in: CGRect(x: ((Double(size) - width) / 2).rounded(),
                                    y: ((Double(size) - height) / 2).rounded(),
                                    width: width, height: height))
    let url = outputURL.appendingPathComponent(name + ".png")
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
}
