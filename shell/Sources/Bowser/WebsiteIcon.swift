import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One procedural icon treatment for every site. No brand database or network
/// lookup beyond the icons declared by the document and its manifest.
enum WebsiteIcon {
    nonisolated static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "bowser.website-icons"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    nonisolated static func prepare(_ data: Data, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        // Form the operation outside MainActor: Swift otherwise inserts a
        // runtime executor assertion even for an @Sendable block operation.
        queue.addOperation {
            let path = cachedPath(for: data)
            DispatchQueue.main.async { completion(path) }
        }
    }

    nonisolated static let probe = #"""
    const links = d => Array.from(d.querySelectorAll('link[rel]')).filter(l => /(^|\s)(icon|shortcut|apple-touch-icon|manifest)(\s|$)/i.test(l.rel));
    const candidates = [];
    const manifests = [];
    function collect(doc, base) {
      for (const link of links(doc)) {
        try {
          const url = new URL(link.getAttribute('href'), base).href;
          if (!/^(https?:|data:image\/)/i.test(url)) continue;
          if (link.rel === 'manifest') { manifests.push(url); continue; }
          candidates.push({url, size: parseInt(link.getAttribute('sizes')) || 0,
            vector: /svg/i.test(link.type || '') || /\.svg([?#]|$)/i.test(url) || url.startsWith('data:image/svg'),
            app: /apple-touch-icon/.test(link.rel)});
        } catch (_) {}
      }
    }
    async function fetchText(url) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 2000);
      try {
        const response = await fetch(url, {signal: controller.signal});
        if (!response.ok) throw Error('icon metadata unavailable');
        const text = await response.text();
        if (text.length > 2000000) throw Error('icon metadata too large');
        return {text, url: response.url};
      } finally { clearTimeout(timer); }
    }
    // Notification badges often replace the original link with a data PNG.
    // Re-read the original declarations only in that case, never site-specific.
    if (/^https?:$/.test(location.protocol) && links(document).some(l => /^data:image\/(png|webp)/i.test(l.href))) {
      try {
        const original = await fetchText(location.href);
        collect(new DOMParser().parseFromString(original.text, 'text/html'), original.url);
      } catch (_) {}
    }
    const hasCleanIcon = candidates.length > 0;
    const originalCount = candidates.length;
    collect(document, document.baseURI);
    if (hasCleanIcon) {
      for (let i = candidates.length - 1; i >= originalCount; --i) {
        if (/^data:image\/(png|webp)/i.test(candidates[i].url)) candidates.splice(i, 1);
      }
    }
    await Promise.all([...new Set(manifests)].slice(0, 2).map(async url => {
      try {
        const response = await fetchText(url), manifest = JSON.parse(response.text);
        for (const icon of (manifest.icons || []).slice(0, 12)) {
          if ((icon.purpose || 'any').split(' ').every(p => p === 'monochrome')) continue;
          const src = new URL(icon.src, response.url).href;
          if (!/^https?:/i.test(src)) continue;
          candidates.push({url: src, size: parseInt(icon.sizes) || 0,
            vector: /svg/i.test(icon.type || ''), app: true});
        }
      } catch (_) {}
    }));
    if (!candidates.length && /^https?:$/.test(location.protocol)) candidates.push({url: location.origin + '/favicon.ico'});
    const seen = new Set();
    const ranked = candidates.sort((a,b) => ((b.vector ? 512 : b.size || 32) + (b.app ? 1 : 0)) - ((a.vector ? 512 : a.size || 32) + (a.app ? 1 : 0)))
      .filter(c => !seen.has(c.url) && seen.add(c.url)).slice(0, 10);
    const results = await Promise.all(ranked.map(async candidate => {
      try {
        const image = new Image(); image.crossOrigin = 'anonymous';
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => { image.src = ''; reject(Error('icon timeout')); }, 2500);
          image.onload = () => { clearTimeout(timer); resolve(); };
          image.onerror = () => { clearTimeout(timer); reject(Error('invalid icon')); };
          image.src = candidate.url;
        });
        if (!image.naturalWidth || !image.naturalHeight) return null;
        const longest = Math.max(image.naturalWidth, image.naturalHeight);
        const scale = (candidate.vector ? 512 : Math.min(512, longest)) / longest;
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
        return {score: Math.min(canvas.width, canvas.height) + (candidate.app ? 0.5 : 0), png: canvas.toDataURL('image/png').split(',')[1]};
      } catch (_) { return null; }
    }));
    return results.filter(Boolean).sort((a,b) => b.score - a.score)[0]?.png || null;
    """#

    nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { return nil }
        return data as Data
    }

    /// ImageIO selects the largest ICO frame and bounds decode size before
    /// sampling. Processing happens off the AppKit thread.
    nonisolated static func normalizedPNG(_ data: Data) -> Data? {
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

    nonisolated static func cachedPath(for data: Data) -> String? {
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = BowserPaths.home.appendingPathComponent("favicons/tiles-v1")
        let file = root.appendingPathComponent(key + ".png")
        if FileManager.default.fileExists(atPath: file.path) { return file.path }
        guard let png = normalizedPNG(data) else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
            return file.path
        } catch { return nil }
    }
}
