import XCTest
import WebKit
@testable import Bowser

@MainActor final class SitePermissionTests: XCTestCase {
    func testOriginsAndFrameIsolation() {
        XCTAssertEqual(SitePermissionKey.origin(URL(string: "https://EXAMPLE.com:443/path?q=1")), "https://example.com")
        XCTAssertEqual(SitePermissionKey.origin(URL(string: "https://example.com:8443")), "https://example.com:8443")
        XCTAssertNil(SitePermissionKey.origin(URL(string: "http://example.com")))
        XCTAssertNil(SitePermissionKey.origin(URL(string: "https://user:secret@example.com")))
        XCTAssertFalse(SitePermissionKey.validRequest(top: "https://example.com", request: "https://sub.example.com", frame: "https://sub.example.com"))
        XCTAssertFalse(SitePermissionKey.validRequest(top: nil, request: nil, frame: nil))
        XCTAssertTrue(SitePermissionKey.validRequest(top: "https://example.com", request: "https://example.com", frame: "https://example.com"))
    }
    func testStoreScopesPersistsAndCombinesMediaDecisions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("permissions.json"), origin = "https://example.com"
        let store = SitePermissionStore(file: file)
        XCTAssertEqual(store.mediaDecision(profile: "default", origin: origin, kinds: ["camera"]), .prompt)
        try store.set(profile: "default", origin: origin, kinds: ["camera"], decision: "allow")
        XCTAssertEqual(store.mediaDecision(profile: "default", origin: origin, kinds: ["camera"]), .grant)
        XCTAssertEqual(store.mediaDecision(profile: "work", origin: origin, kinds: ["camera"]), .prompt)
        XCTAssertEqual(store.mediaDecision(profile: "default", origin: "https://sub.example.com", kinds: ["camera"]), .prompt)
        XCTAssertEqual(store.mediaDecision(profile: "default", origin: origin, kinds: ["camera", "microphone"]), .prompt)
        try store.set(profile: "default", origin: origin, kinds: ["microphone"], decision: "block")
        XCTAssertEqual(store.mediaDecision(profile: "default", origin: origin, kinds: ["camera", "microphone"]), .deny)
        let loaded = SitePermissionStore(file: file)
        XCTAssertEqual(loaded.decision(profile: "default", origin: origin, kind: "microphone"), "block")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        try store.set(profile: "work", origin: origin, kinds: ["camera"], decision: "allow")
        try store.reset(profile: "default")
        XCTAssertEqual(store.decision(profile: "work", origin: origin, kind: "camera"), "allow")
        XCTAssertEqual(store.decision(profile: "default", origin: origin, kind: "camera"), "ask")
        XCTAssertThrowsError(try store.set(profile: "default", origin: origin + "/path", kinds: ["camera"], decision: "allow"))
    }
    func testSettingsEditsAndResetsOnlySelectedProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SitePermissionStore(file: dir.appendingPathComponent("permissions.json"))
        let model = PermissionSettingsModel(store: store)
        model.selectedOrigin = "https://example.com"
        model.set("camera", choice: "allow")
        XCTAssertEqual(model.controls.first { $0.id == "camera" }?.choice, "allow")
        model.selectedProfile = "work"; model.selectedOrigin = "https://example.com"
        XCTAssertEqual(model.controls.first { $0.id == "camera" }?.choice, "ask")
        model.set("camera", choice: "block")
        model.resetSite()
        XCTAssertEqual(model.controls.first { $0.id == "camera" }?.choice, "ask")
        XCTAssertEqual(store.decision(profile: "default", origin: "https://example.com", kind: "camera"), "allow")
    }

    func testWebKitMediaDelegateIsActuallyExported() {
        let engine = EngineView(frame: .zero)
        defer { engine.tearDown() }
        XCTAssertTrue(engine.responds(to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
    }
}

@MainActor final class NotificationPermissionPolicyTests: XCTestCase {
    func testPlatformDenialAndSiteBlockingOverrideAllow() {
        XCTAssertEqual(SiteAppNotifications.effectivePermission(choice: "allow", authorization: .denied), "denied")
        XCTAssertEqual(SiteAppNotifications.effectivePermission(choice: "block", authorization: .authorized), "denied")
        XCTAssertEqual(SiteAppNotifications.effectivePermission(choice: "ask", authorization: .authorized), "default")
        XCTAssertEqual(SiteAppNotifications.effectivePermission(choice: "allow", authorization: .notDetermined), "default")
        XCTAssertEqual(SiteAppNotifications.effectivePermission(choice: "allow", authorization: .authorized), "granted")
    }
    func testNotificationResetPreservesCameraAndOtherProfiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SitePermissionStore(file: dir.appendingPathComponent("permissions.json")), origin = "https://example.com"
        try store.set(profile: "default", origin: origin, kinds: ["notifications", "camera"], decision: "allow")
        try store.set(profile: "work", origin: origin, kinds: ["notifications"], decision: "block")
        try store.reset(profile: "default", kind: "notifications")
        XCTAssertEqual(store.decision(profile: "default", origin: origin, kind: "notifications"), "ask")
        XCTAssertEqual(store.decision(profile: "default", origin: origin, kind: "camera"), "allow")
        XCTAssertEqual(store.decision(profile: "work", origin: origin, kind: "notifications"), "block")
    }
}
