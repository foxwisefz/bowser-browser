import XCTest
import AppKit
@testable import Bowser

final class NativeAssetTests: XCTestCase {
    @MainActor func testSVGLoadsAndUpdatesAtSamePath() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".svg")
        defer { try? FileManager.default.removeItem(at: path) }
        func write(_ color: String, at date: Date) throws {
            let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"\(color)\"/></svg>"
            try svg.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
        func pixel() throws -> NSColor {
            let image = try XCTUnwrap(ImageCache.load(path.path))
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            return try XCTUnwrap(bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
        }
        try write("red", at: Date(timeIntervalSince1970: 100))
        XCTAssertGreaterThan(try pixel().redComponent, 0.9)
        try write("blue", at: Date(timeIntervalSince1970: 200))
        XCTAssertGreaterThan(try pixel().blueComponent, 0.9)
        try FileManager.default.removeItem(at: path)
        XCTAssertNil(ImageCache.load(path.path))
    }
}
