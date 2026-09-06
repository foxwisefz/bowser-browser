import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Package the complete supplied icon, retaining its existing alpha and frame.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read the application artwork")
}

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
