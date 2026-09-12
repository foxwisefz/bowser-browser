import XCTest
@testable import Bowser

final class ProfileTests: XCTestCase {
    func testHexColorParsing() {
        XCTAssertNotNil(Profile.color(hex: "#3e63dd"))
        XCTAssertNil(Profile.color(hex: "#fff"))
        XCTAssertNil(Profile.color(hex: "blue"))
        XCTAssertNil(Profile.color(hex: nil))
        let c = Profile.color(hex: "#ff0000")!.usingColorSpace(.sRGB)!
        XCTAssertEqual(c.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(c.greenComponent, 0, accuracy: 0.001)
    }

    func testStoreUUIDHonorsTheBrainsUUIDAndIsStableOtherwise() {
        let minted = "0f1e2d3c-4b5a-4978-8a9b-0c1d2e3f4a5b"
        XCTAssertEqual(Profile.storeUUID(id: "work", uuid: minted).uuidString.lowercased(), minted)
        let a = Profile.storeUUID(id: "work", uuid: nil)
        let b = Profile.storeUUID(id: "work", uuid: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, Profile.storeUUID(id: "play", uuid: nil))
    }

    func testEnsureDefaultKeepsTheDefaultFirst() {
        let list = [Profile(id: "work", name: "Work", tint: nil, icon: nil, uuid: nil)]
        XCTAssertEqual(Profile.ensureDefault(list).map(\.id), ["default", "work"])
        XCTAssertEqual(Profile.ensureDefault([]).map(\.id), ["default"])
    }

    func testConfiguredDefaultIsNotRewritten() {
        let configured = Profile(id: "default", name: "Personal", tint: "#ab0500", icon: nil, uuid: nil)
        XCTAssertEqual(Profile.ensureDefault([configured]), [configured])
        XCTAssertEqual(Profile.defaultProfile.avatar, .bowser)
    }

    func testCharacterPersistenceAndLegacyProfileCompatibility() throws {
        let old = Data(#"{"id":"work","name":"Work","icon":"🧪","uuid":null,"tint":null}"#.utf8)
        let legacy = try JSONDecoder().decode(Profile.self, from: old)
        XCTAssertNil(legacy.avatar)
        XCTAssertEqual(legacy.label, "🧪 Work")
        var updated = legacy
        updated.character = "bowser"
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded.avatar, .bowser)
        XCTAssertEqual(decoded.label, "Work")
        XCTAssertEqual(decoded.uuid, legacy.uuid)
        updated.character = "future-character"
        XCTAssertNil(updated.avatar)
        XCTAssertEqual(updated.label, "🧪 Work")
    }

    @MainActor func testEveryCharacterHasBundledTransparentArtwork() throws {
        for character in ProfileCharacter.allCases {
            let image = try XCTUnwrap(character.image, "Missing bundled portrait: \(character.rawValue)")
            let data = try XCTUnwrap(image.tiffRepresentation)
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(pixels.pixelsWide, Int(character.sprite.rect.width))
            XCTAssertEqual(pixels.pixelsHigh, Int(character.sprite.rect.height))
            XCTAssertTrue(pixels.hasAlpha)
            XCTAssertNotNil(Profile.color(hex: character.tint))
        }
    }

    @MainActor func testFriendlyBowserLowerLeftShadowIsTransparent() throws {
        let image = try XCTUnwrap(ProfileCharacter.bowser.image)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        // Source-sheet points in the residual shadow, whose alpha ranges
        // from 205 to 224; the old alpha-only cutoff left these visible.
        for (x, y) in [(450, 365), (458, 375), (466, 385)] {
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x - 409, y: y - 206)).alphaComponent, 0)
        }
        // Keep the navy outline, cheek, and slightly translucent eye whites.
        for (x, y) in [(466, 375), (486, 365), (531, 293)] {
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x - 409, y: y - 206)).alphaComponent, 0.95)
        }
    }
}

final class ColorPickerHexTests: XCTestCase {
    func testHexRoundTripsThroughProfileColor() {
        for hex in ["#3e63dd", "#30a46c", "#000000", "#ffffff"] {
            let color = Profile.color(hex: hex)!
            XCTAssertEqual(SurfaceColorPickerHexBridge.hex(color), hex)
        }
    }
}

final class BowserPathsTests: XCTestCase {
    func testDefaultHomeIsDotBowser() {
        if ProcessInfo.processInfo.environment["BOWSER_HOME"] == nil {
            XCTAssertEqual(BowserPaths.home.lastPathComponent, ".bowser")
        }
    }
}
