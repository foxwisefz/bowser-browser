import XCTest
import CryptoKit
@testable import Bowser

final class UpdateTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    func envelope(build: String = "200", url: String = "https://api.bowser.app/updates/Bowser.dmg", expiry: Date = Date().addingTimeInterval(3600), os: Int = 15) throws -> Data {
        let release = UpdateRelease(version: "test", build: build, minimumMacOS: os, url: URL(string: url)!, bytes: 3,
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
        for url in ["http://api.bowser.app/updates/Bowser.dmg", "https://evil.invalid/update", "https://bowser.app/updates/Bowser.dmg", "https://www.bowser.app/updates/Bowser.dmg", "https://user@api.bowser.app/file"] {
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
}
