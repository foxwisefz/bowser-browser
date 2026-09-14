import AppKit
import SwiftUI
import XCTest
@testable import Bowser

@MainActor
final class OnboardingTests: XCTestCase {
    func testProductionRegistrationEndpoint() {
        XCTAssertEqual(RegistrationService().endpoint.absoluteString, "https://api.bowser.app/v1/registrations")
    }

    let policy = RegistrationPolicy(termsVersion: "test-terms",
        termsURL: URL(string: "https://example.invalid/terms")!)

    func store() -> RegistrationStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RegistrationStore(directory: directory)
    }

    func testEmailAndExplicitConsentAreBothRequired() async {
        let model = OnboardingModel(policy: policy, store: store()) { _ in
            XCTFail("Invalid forms must not submit"); throw RegistrationFailure.invalidResponse
        }
        XCTAssertFalse(model.acceptedTerms)
        for bad in ["", "a", "a@", "a@b", "a@@b.com", "a b@example.com", "a@example..com"] {
            model.email = bad; model.acceptedTerms = true
            XCTAssertFalse(model.canSubmit, bad)
            await model.submit()
        }
        model.email = " Person+tag@example.com \n"
        model.acceptedTerms = false
        XCTAssertFalse(model.canSubmit)
        await model.submit()
        model.acceptedTerms = true
        XCTAssertTrue(model.canSubmit)
        XCTAssertEqual(OnboardingModel.normalizedEmail(model.email), "Person+tag@example.com")
    }

    func testSuccessfulResponsePersistsVersionedReceiptPrivately() async throws {
        let disk = store()
        let model = OnboardingModel(policy: policy, store: disk) {
            RegistrationReceipt(registrationID: "fixture-id", request: $0)
        }
        model.email = " person@example.com "; model.acceptedTerms = true
        await model.submit()
        let receipt = try XCTUnwrap(model.receipt)
        XCTAssertEqual(receipt.request.email, "person@example.com")
        XCTAssertEqual(receipt.request.termsVersion, policy.termsVersion)
        XCTAssertEqual(try disk.load(), receipt)
        let mode = try FileManager.default.attributesOfItem(atPath: disk.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.error)
    }

    actor FailingThenSuccessfulService {
        var requests: [RegistrationRequest] = []
        func submit(_ request: RegistrationRequest) throws -> RegistrationReceipt {
            requests.append(request)
            if requests.count == 1 { throw RegistrationFailure.invalidResponse }
            return RegistrationReceipt(registrationID: "fixture", request: request)
        }
        func captured() -> [RegistrationRequest] { requests }
    }

    func testRetryKeepsDraftConsentAndIdempotencyIdentity() async throws {
        let disk = store(), service = FailingThenSuccessfulService()
        let model = OnboardingModel(policy: policy, store: disk) { try await service.submit($0) }
        model.email = "person@example.com"; model.acceptedTerms = true
        await model.submit()
        XCTAssertNil(model.receipt)
        XCTAssertNil(try disk.load())
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(model.acceptedTerms)
        await model.submit()
        let sent = await service.captured()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        XCTAssertNotNil(model.receipt)
    }

    func testMismatchedReceiptCannotCompleteSetup() async throws {
        let disk = store()
        let model = OnboardingModel(policy: policy, store: disk) { request in
            let other = RegistrationRequest(requestID: UUID(), email: request.email,
                termsVersion: request.termsVersion, acceptedAt: request.acceptedAt)
            return RegistrationReceipt(registrationID: "wrong-request", request: other)
        }
        model.email = "person@example.com"; model.acceptedTerms = true
        await model.submit()
        XCTAssertNil(model.receipt)
        XCTAssertNil(try disk.load())
        XCTAssertNotNil(model.error)
    }

    func testTransportRejectsInsecureEndpointWithoutSending() async {
        let request = RegistrationRequest(requestID: UUID(), email: "person@example.com",
            termsVersion: "test", acceptedAt: Date())
        do {
            _ = try await RegistrationService(endpoint: URL(string: "http://example.invalid/register")!).submit(request)
            XCTFail("Plain HTTP must not send registration data")
        } catch { }
    }

    func testRenderWelcomeAndReady() throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_ONBOARDING_RENDER"] else {
            throw XCTSkip("Optional native render")
        }
        _ = NSApplication.shared
        let model = OnboardingModel(policy: policy, store: store()) { _ in throw RegistrationFailure.invalidResponse }
        for populated in [false, true] {
            model.email = populated ? "person@example.com" : ""
            model.acceptedTerms = populated
            let view = NSHostingView(rootView: OnboardingView(model: model, finished: {}))
            view.frame = NSRect(x: 0, y: 0, width: 552, height: 520)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(populated ? "ready.png" : "welcome.png"))
        }
    }
}
