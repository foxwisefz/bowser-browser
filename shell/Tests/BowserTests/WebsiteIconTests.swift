import AppKit
import ImageIO
import IconRendering
import XCTest
@testable import Bowser

final class WebsiteIconTests: XCTestCase {
    func fixture(circle: Bool = false, transparent: Bool = false) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [88.0/255, 101.0/255, 242.0/255, 1])!)
            if circle { context.fillEllipse(in: CGRect(x: 0, y: 0, width: 256, height: 256)) }
            else { context.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        // A wide mark to ensure normalization preserves its aspect ratio.
        context.fill(CGRect(x: 48, y: 88, width: 160, height: 80))
        return try XCTUnwrap(IconRenderer.png(context.makeImage()!))
    }

    func testCircleBecomesPaddedTileWithSampledBackground() throws {
        let normalized = try XCTUnwrap(IconRenderer.normalizedPNG(fixture(circle: true)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: normalized))
        XCTAssertEqual(bitmap.pixelsWide, 1024)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        XCTAssertEqual(bitmap.colorAt(x: 105, y: 105)?.alphaComponent, 0)
        let background = try XCTUnwrap(bitmap.colorAt(x: 512, y: 120)?.usingColorSpace(.sRGB))
        XCTAssertEqual(background.blueComponent, 242.0/255, accuracy: 0.015)
        XCTAssertGreaterThan(bitmap.colorAt(x: 270, y: 512)!.usingColorSpace(.sRGB)!.redComponent, 0.95)
        // 500x250 mark, not a stretched square.
        XCTAssertLessThan(bitmap.colorAt(x: 512, y: 350)!.usingColorSpace(.sRGB)!.redComponent, 0.5)
        XCTAssertEqual(IconRenderer.normalizedPNG(try fixture(circle: true)), normalized)
    }

    func testSparseWhiteLogoGetsAContrastingTile() throws {
        let data = try XCTUnwrap(IconRenderer.normalizedPNG(fixture(transparent: true)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let background = try XCTUnwrap(bitmap.colorAt(x: 512, y: 120)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(background.redComponent, 0.3)
        XCTAssertGreaterThan(bitmap.colorAt(x: 512, y: 512)!.usingColorSpace(.sRGB)!.redComponent, 0.95)
    }

    @MainActor
    func testProfileBadgeIsAtUpperRightAndLeavesSiteMarkIntact() throws {
        let tile = try XCTUnwrap(IconRenderer.normalizedPNG(fixture()))
        let portrait = try XCTUnwrap(ProfileCharacter.bowser.image?.tiffRepresentation)
        let badged = try XCTUnwrap(IconRenderer.badgedPNG(tile, badge: portrait))
        let before = try XCTUnwrap(NSBitmapImageRep(data: tile))
        let after = try XCTUnwrap(NSBitmapImageRep(data: badged))
        XCTAssertEqual(before.colorAt(x: 512, y: 512), after.colorAt(x: 512, y: 512))
        XCTAssertEqual(before.colorAt(x: 832, y: 832), after.colorAt(x: 832, y: 832))
        // Bitmap coordinates are top-down. The badge stays inside the tile
        // so macOS does not shrink it into another padded background.
        XCTAssertEqual(after.colorAt(x: 940, y: 192)?.alphaComponent, 0)
        XCTAssertNotEqual(before.colorAt(x: 752, y: 272), after.colorAt(x: 752, y: 272))
        for y in stride(from: 0, to: 1024, by: 8) {
            for x in stride(from: 0, to: 1024, by: 8) {
                XCTAssertEqual(before.colorAt(x: x, y: y)?.alphaComponent,
                               after.colorAt(x: x, y: y)?.alphaComponent)
            }
        }
        let other = try XCTUnwrap(IconRenderer.badgedPNG(tile, badge: XCTUnwrap(ProfileCharacter.shyGuy.image?.tiffRepresentation)))
        XCTAssertNotEqual(badged, other)
        try badged.write(to: URL(fileURLWithPath: "/private/tmp/bowser-profile-badge-preview.png"))
        XCTAssertNotNil(IconRenderer.icns(badged))
    }

    func testInvalidAndOversizedInputsAreRejected() {
        XCTAssertNil(IconRenderer.normalizedPNG(Data("bad image".utf8)))
        XCTAssertNil(IconRenderer.normalizedPNG(Data(repeating: 0, count: 4_000_001)))
    }

    @MainActor
    func testICNSContainsDockAndRetinaSizes() throws {
        let image = try XCTUnwrap(NSImage(data: IconRenderer.normalizedPNG(fixture())!))
        let icns = try XCTUnwrap(IconRenderer.icns(image.tiffRepresentation!))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(icns as CFData, nil))
        let sizes = Set((0..<CGImageSourceGetCount(source)).compactMap { index -> Int? in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int
        })
        XCTAssertTrue(sizes.isSuperset(of: [16,32,64,128,256,512,1024]))
        XCTAssertNotNil(NSImage(data: icns))
    }

    func testAppCacheSeparatesProfilesAndOrigins() {
        let root = URL(string: "https://example.com")!
        XCTAssertEqual(TabAppBundle.iconKey(url: root, profile: "work"), TabAppBundle.iconKey(url: URL(string: "https://example.com/other")!, profile: "work"))
        XCTAssertNotEqual(TabAppBundle.iconKey(url: root, profile: "work"), TabAppBundle.iconKey(url: root, profile: "personal"))
        XCTAssertNotEqual(TabAppBundle.iconKey(url: root, profile: "work"), TabAppBundle.iconKey(url: URL(string: "https://example.com:444")!, profile: "work"))
    }

    func testRenderWebsiteFixturesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_ICON_FIXTURES"] else { throw XCTSkip("Optional visual verification with website-fetched fixtures") }
        let root = URL(fileURLWithPath: path)
        for (name, file) in [("twitter", "twitter-source.png"), ("discord", "discord-clean.ico")] {
            let data = try Data(contentsOf: root.appendingPathComponent(file))
            let output = try XCTUnwrap(IconRenderer.normalizedPNG(data))
            try output.write(to: root.appendingPathComponent(name + "-native.png"))
        }
    }
}
