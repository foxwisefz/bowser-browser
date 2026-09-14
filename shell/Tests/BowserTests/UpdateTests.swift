import XCTest
import CryptoKit
@testable import Bowser

final class UpdateTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    func envelope(build: String = "200", url: String? = nil, expiry: Date = Date().addingTimeInterval(3600), os: Int = 15) throws -> Data {
        let release = UpdateRelease(version: "test", build: build, minimumMacOS: os, url: URL(string: url ?? "https://assets.bowser.app/releases/\(build)/Bowser.dmg")!, bytes: 3,
            sha256: SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(), expiresAt: expiry)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(release)
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
    }
    func verify(_ data: Data, key supplied: Data? = nil) throws -> UpdateRelease? {
        try UpdateRelease.verified(data, publicKey: supplied ?? key.publicKey.rawRepresentation, currentBuild: "100", osMajor: 15)
    }
    func testSignedUpgradeRejectsWrongKeyTamperingExpiryAndWrongOrigin() throws {
        XCTAssertNotNil(try verify(envelope()))
        XCTAssertNil(try verify(envelope(build: "99")))
        XCTAssertNil(try verify(envelope(build: "100")))
        XCTAssertThrowsError(try verify(envelope(), key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        for url in ["http://api.bowser.app/updates/Bowser.dmg", "https://evil.invalid/update", "https://assets.bowser.app/releases/999/Bowser.dmg", "https://assets.bowser.app/releases/200/Bowser.dmg?x=1", "https://api.bowser.app/updates/Bowser.dmg", "https://bowser.app/updates/Bowser.dmg", "https://www.bowser.app/updates/Bowser.dmg", "https://user@api.bowser.app/file"] {
            XCTAssertThrowsError(try verify(envelope(url: url)))
        }
        XCTAssertThrowsError(try verify(envelope(expiry: Date().addingTimeInterval(-1))))
        XCTAssertThrowsError(try verify(envelope(os: 99)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope()) as? [String: String])
        json["payload"] = Data("tampered".utf8).base64EncodedString()
        XCTAssertThrowsError(try verify(JSONSerialization.data(withJSONObject: json)))
    }
    func testImageHashAndSizeMustMatchSignedManifest() throws {
        let release = try XCTUnwrap(verify(envelope()))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file); XCTAssertNoThrow(try release.verifyFile(file))
        try Data("xyz".utf8).write(to: file); XCTAssertThrowsError(try release.verifyFile(file))
        try Data("abcd".utf8).write(to: file); XCTAssertThrowsError(try release.verifyFile(file))
    }
    func testPreparedBuildPreventsRepeatDownloadWithoutHidingNewerInstalledBuild() {
        XCTAssertEqual(AppUpdates.latestBuild("100", "200"), "200")
        XCTAssertEqual(AppUpdates.latestBuild("300", "200"), "300")
        XCTAssertEqual(AppUpdates.latestBuild("100", nil), "100")
        XCTAssertEqual(AppUpdates.latestBuild("100", "invalid"), "100")
    }

    func testModulesPublishVerifiedCopiesAndLeavePointerOnVerificationFailure() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("app.bundle")
        let build = String(repeating: "a", count: 32)
        for (name, identifier) in [("SurfaceRenderer", "surfaces"), ("CommandToolbar", "command-toolbar")] {
            let contents = app.appendingPathComponent("Contents/Resources/\(name).bundle/Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "com.foxwiseai.bowser." + identifier, "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        // Real verification must reject the unsigned fixture before publishing anything.
        XCTAssertThrowsError(try UpdateInstaller.publishModules(from: app, home: home))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("native-modules/surfaces/current").path))
        var verified: [URL] = []
        try UpdateInstaller.publishModules(from: app, home: home) { verified.append($0) }
        XCTAssertEqual(verified.count, 4) // Source and copied generation for both modules.
        for kind in ["surfaces", "command-toolbar"] {
            let root = home.appendingPathComponent("native-modules/" + kind)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("current"), encoding: .utf8), build + "\n")
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(build + ".bundle/Contents/Info.plist").path))
        }
        XCTAssertThrowsError(try UpdateInstaller.publishModules(from: app, home: home) { _ in throw UpdateError.invalidRelease })
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("native-modules/surfaces/current"), encoding: .utf8), build + "\n")
        verified = []
        try UpdateInstaller.publishModules(from: app, home: home) { verified.append($0) }
        XCTAssertEqual(verified.count, 4) // Retry validates existing immutable generations too.
    }

}
