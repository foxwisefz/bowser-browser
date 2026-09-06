import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Asset packaging, not a redraw: retain the supplied pixel art and heart.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let crop = sheet.cropping(to: CGRect(x: 434, y: 206, width: 152, height: 193)),
      let matte = CGContext(data: nil, width: crop.width, height: crop.height,
                            bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let pixels = matte.data?.assumingMemoryBound(to: UInt8.self) else {
    fatalError("Cannot read the friendly Bowser sprite")
}
// Match the profile renderer: discard the cutout's residual translucent
// shadow and background speckles, retaining the opaque face and heart.
matte.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
for offset in stride(from: 0, to: crop.width * crop.height * 4, by: 4) {
    let alpha = pixels[offset + 3]
    let high = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
    let low = min(pixels[offset], min(pixels[offset + 1], pixels[offset + 2]))
    let neutralMatte = alpha < 255 && high <= 60 && high - low <= 8
    if alpha < 200 || neutralMatte {
        for channel in 0..<4 { pixels[offset + channel] = 0 }
    }
}
guard let sprite = matte.makeImage() else { fatalError("Cannot prepare the icon cutout") }

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
    context.interpolationQuality = .none
    let height = (Double(size) * 0.88).rounded()
    let width = (height * Double(sprite.width) / Double(sprite.height)).rounded()
    context.draw(sprite, in: CGRect(x: ((Double(size) - width) / 2).rounded(),
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
