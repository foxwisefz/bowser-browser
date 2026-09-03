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
}
