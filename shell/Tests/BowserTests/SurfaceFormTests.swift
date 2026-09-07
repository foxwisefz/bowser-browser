import XCTest
@testable import Bowser

final class SurfaceFormTests: XCTestCase {
    @MainActor
    func testRefreshPreservesDraftAndRevertUsesBaseline() {
        let model = SurfaceFormModel(["name": "Original"])
        model.values["name"] = "Draft"
        model.refresh(["name": "Remote"], response: nil)
        XCTAssertEqual(model.values["name"] as? String, "Draft")
        model.reset()
        XCTAssertEqual(model.values["name"] as? String, "Original")
        model.refresh(["name": "Remote"], response: nil)
        XCTAssertEqual(model.values["name"] as? String, "Remote")
    }

    @MainActor
    func testValidationAndMatchingAcknowledgement() throws {
        let model = SurfaceFormModel(["name": "   "])
        XCTAssertNil(model.begin(required: ["name"]))
        XCTAssertNotNil(model.errors["name"])
        model.values["name"] = "Draft"
        let request = try XCTUnwrap(model.begin(required: ["name"]))
        XCTAssertNil(model.begin(required: []))
        model.refresh([:], response: ["request_id": "old", "ok": true])
        XCTAssertTrue(model.busy)
        model.refresh([:], response: ["request_id": request["request_id"]!, "ok": false, "errors": ["name": "Already taken"]])
        XCTAssertEqual(model.values["name"] as? String, "Draft")
        XCTAssertEqual(model.errors["name"], "Already taken")
        XCTAssertFalse(model.busy)
        let retry = try XCTUnwrap(model.begin(required: ["name"]))
        model.refresh([:], response: ["request_id": retry["request_id"]!, "ok": true, "values": ["name": "Canonical"]])
        XCTAssertEqual(model.values["name"] as? String, "Canonical")
        XCTAssertFalse(model.dirty)
    }

    @MainActor
    func testTimeoutPreservesDraftAndStaleTimeoutCannotEndNewRequest() throws {
        let model = SurfaceFormModel(["name": "Before"])
        model.values["name"] = "After"
        let first = try XCTUnwrap(model.begin(required: [])?["request_id"] as? String)
        model.expire(first)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.dirty)
        XCTAssertNotNil(model.errors["_form"])
        _ = model.begin(required: [])
        model.expire(first)
        XCTAssertTrue(model.busy)
    }

    @MainActor
    func testFormsAreScopedToSurfaceAndSurviveRemount() {
        let store = SurfaceFormStore()
        let model = store.model(surface: "one", key: "editor", initial: ["name": "A"])
        model.values["name"] = "Unsaved"
        XCTAssertTrue(model === store.model(surface: "one", key: "editor", initial: [:]))
        XCTAssertFalse(model === store.model(surface: "two", key: "editor", initial: [:]))
        store.remove(surface: "one")
        XCTAssertFalse(model === store.model(surface: "one", key: "editor", initial: [:]))
    }

    func testKeysSurviveReorderingAndDuplicateFallbackIsUnique() {
        let a: [String: Any] = ["key": "a", "value": "A"]
        let b: [String: Any] = ["key": "b", "value": "B"]
        XCTAssertEqual(SurfaceNode.children([a, b]).first?.id, SurfaceNode.children([b, a]).last?.id)
        let duplicate = SurfaceNode.children([a, a, [:], [:]])
        XCTAssertEqual(Set(duplicate.map(\.id)).count, 4)
    }
}
