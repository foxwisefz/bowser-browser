import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum IconRenderer {
    public nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { return nil }
        return data as Data
    }

    /// ImageIO selects the largest ICO frame and bounds decode size before
    /// sampling. This code is linked only into the disposable worker.
    public nonisolated static func normalizedPNG(_ data: Data) -> Data? {
        guard data.count <= 4_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let index = (0..<CGImageSourceGetCount(source)).max { a, b in
            func size(_ i: Int) -> Int {
                let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                return props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            }
            return size(a) < size(b)
        } ?? 0
        guard let original = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        let w = original.width, h = original.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let sample = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w * 4, space: colorSpace, bitmapInfo: info),
              let bytes = sample.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        sample.draw(original, in: CGRect(x: 0, y: 0, width: w, height: h))
        var colors: [Int: Int] = [:], opaque = 0
        for i in 0..<(w * h) where bytes[i * 4 + 3] > 245 {
            let key = Int(bytes[i * 4]) << 16 | Int(bytes[i * 4 + 1]) << 8 | Int(bytes[i * 4 + 2])
            colors[key, default: 0] += 1; opaque += 1
        }
        guard let dominant = colors.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }) else { return nil }
        var rgb = [(dominant.key >> 16) & 255, (dominant.key >> 8) & 255, dominant.key & 255]
        // A sparse transparent mark needs contrast, not a tile of its own ink.
        let flatBackground = opaque > w * h / 2 && dominant.value > opaque / 3
        if !flatBackground {
            let light = rgb.reduce(0, +) > 420
            rgb = light ? [38, 40, 46] : [242, 243, 245]
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        let r = rgb[0], g = rgb[1], b = rgb[2]
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, inverseAlpha = 255 - Int(bytes[i + 3])
            let pr = Int(bytes[i]) + r * inverseAlpha / 255
            let pg = Int(bytes[i + 1]) + g * inverseAlpha / 255
            let pb = Int(bytes[i + 2]) + b * inverseAlpha / 255
            if max(abs(pr - r), abs(pg - g), abs(pb - b)) > 45 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
            bytes[i] = UInt8(clamping: pr); bytes[i + 1] = UInt8(clamping: pg)
            bytes[i + 2] = UInt8(clamping: pb); bytes[i + 3] = 255
        }}
        guard let flattened = sample.makeImage() else { return nil }
        let bounds = maxX >= minX ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                                 : CGRect(x: 0, y: 0, width: w, height: h)
        // Full-color/complex art is kept intact rather than treating an
        // arbitrary frequent color as a removable background.
        let crop = flatBackground ? bounds : CGRect(x: 0, y: 0, width: w, height: h)
        guard let mark = flattened.cropping(to: crop),
              let output = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                     bytesPerRow: 4096, space: colorSpace, bitmapInfo: info) else { return nil }
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        output.addPath(CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil))
        output.setFillColor(CGColor(colorSpace: colorSpace, components: rgb.map { CGFloat($0) / 255 } + [1])!)
        output.fillPath()
        let scale = (flatBackground ? 500.0 : 640.0) / CGFloat(max(mark.width, mark.height))
        let size = CGSize(width: CGFloat(mark.width) * scale, height: CGFloat(mark.height) * scale)
        output.interpolationQuality = .high
        output.draw(mark, in: CGRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2, width: size.width, height: size.height))
        return output.makeImage().flatMap(png)
    }


    /// Keep the website tile intact and overlay the profile at its upper right.
    /// Only the saved app ICNS uses this; tab favicons remain unbadged.
    public static func badgedPNG(_ tile: Data, badge: Data) -> Data? {
        guard tile.count <= 4_000_000, badge.count <= 1_500_000,
              let source = CGImageSourceCreateWithData(tile as CFData, nil),
              let base = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let badgeSource = CGImageSourceCreateWithData(badge as CFData, nil),
              let portrait = CGImageSourceCreateThumbnailAtIndex(badgeSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary),
              let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        // Quartz has its origin at the lower left. Leave enough edge padding
        // for the badge to survive Dock scaling without clipping its outline.
        let circle = CGRect(x: 688, y: 688, width: 288, height: 288)
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let scale = 248 / CGFloat(max(portrait.width, portrait.height))
        let size = CGSize(width: CGFloat(portrait.width) * scale, height: CGFloat(portrait.height) * scale)
        ctx.interpolationQuality = .high
        ctx.draw(portrait, in: CGRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                      width: size.width, height: size.height))
        return ctx.makeImage().flatMap(png)
    }

    public static func icns(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        func size(_ n: Int) -> Data {
            var value = UInt32(n).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        var chunks = Data()
        for (pixels, type) in [(16,"icp4"),(32,"icp5"),(64,"icp6"),(128,"ic07"),(256,"ic08"),(512,"ic09"),(1024,"ic10")] {
            guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard let resized = ctx.makeImage(), let png = png(resized) else { return nil }
            chunks += Data(type.utf8) + size(png.count + 8) + png
        }
        return Data("icns".utf8) + size(chunks.count + 8) + chunks
    }
}
