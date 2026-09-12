import AppKit

// One cache shared by all rendering generations; retired libraries retain no assets.
@MainActor
public enum ImageCache {
    private static var cache: [String: (Date, NSImage)] = [:]

    public static func load(_ path: String) -> NSImage? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else {
            cache.removeValue(forKey: path)
            return nil
        }
        if let cached = cache[path], cached.0 == modified { return cached.1 }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = (modified, image)
        return image
    }
}

