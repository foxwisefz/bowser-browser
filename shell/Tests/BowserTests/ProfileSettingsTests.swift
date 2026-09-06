import XCTest
@testable import Bowser

final class ProfileSettingsTests: XCTestCase {
    @MainActor
    func testFailedSaveKeepsDraftAndIgnoresUnrelatedResponses() {
        var sent: [String: Any] = [:]
        let model = ProfileSettingsModel(profiles: [.defaultProfile], send: { sent = $0 })
        model.draft.name = "Updated"
        model.save()
        XCTAssertTrue(model.isBusy)
        model.receive(["request_id": "unrelated", "ok": true])
        XCTAssertTrue(model.isBusy)
        model.receive(["request_id": sent["request_id"]!, "ok": false, "error": "Name already exists"])
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.draft.name, "Updated")
        XCTAssertEqual(model.error, "Name already exists")
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func testCreationWaitsForAcknowledgementAndSelectsCreatedProfile() {
        var sent: [String: Any] = [:]
        let model = ProfileSettingsModel(profiles: [.defaultProfile], send: { sent = $0 })
        model.isPresentingCreate = true
        var draft = ProfileDraft.newProfile
        draft.name = " Work "
        model.create(draft)
        XCTAssertEqual((sent["values"] as? [String: Any])?["name"] as? String, "Work")
        let created = Profile(id: "work", name: "Work", tint: draft.tint, character: "bowser")
        model.replaceProfiles([.defaultProfile, created])
        XCTAssertTrue(model.isPresentingCreate)
        model.receive(["request_id": sent["request_id"]!, "ok": true, "profile_id": "work"])
        XCTAssertEqual(model.selectedID, "work")
        XCTAssertFalse(model.isPresentingCreate)
        XCTAssertFalse(model.hasChanges)
    }

    @MainActor
    func testProfileRefreshPreservesUnsavedEdits() {
        let model = ProfileSettingsModel(profiles: [.defaultProfile], send: { _ in })
        model.draft.name = "My draft"
        model.replaceProfiles([.defaultProfile])
        XCTAssertEqual(model.draft.name, "My draft")
        model.revert()
        XCTAssertFalse(model.hasChanges)
    }
}
