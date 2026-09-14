import XCTest
import SwiftUI
import Combine
import BowserSurfaceKit
@testable import Bowser

@MainActor final class BrowserScreenTests: XCTestCase {
    final class Form: ObservableObject, OnboardingPresentation {
        @Published var email = "draft@example.com"
        var acceptedTerms = true
        var trainingConsent = false
        var submitting = false
        var error: String?
        var completed = false
        var termsURL = URL(string: "https://www.bowser.app/terms.html")!
        var canSubmit = true
        var submissions = 0
        func submit() async { submissions += 1 }
        func finish() {}
    }
    func testScreenStateAndObservationSurviveNewRenderRoots() {
        let model = Form()
        let context = BrowserScreenContext(kind: "onboarding", model: model)
        var changes = 0
        let observation = context.objectWillChange.sink { changes += 1 }
        let first = BrowserScreenRoot(context: context)
        context.binding("expanded", default: false).wrappedValue = true
        model.email = "still-here@example.com"
        let second = BrowserScreenRoot(context: context)
        XCTAssertTrue(first.context === second.context)
        XCTAssertTrue(second.context.model === model)
        XCTAssertEqual(model.email, "still-here@example.com")
        XCTAssertTrue(context.binding("expanded", default: false).wrappedValue)
        XCTAssertGreaterThanOrEqual(changes, 2)
        withExtendedLifetime(observation) {}
    }
    func testSignedScreenModuleUsesTheHostModel() async throws {
        _ = NSApplication.shared
        guard let path = ProcessInfo.processInfo.environment["BOWSER_TEST_SCREEN_MODULE"] else {
            throw XCTSkip("Set BOWSER_TEST_SCREEN_MODULE to a built screen renderer")
        }
        let library = try NativeModuleLibrary(bundle: URL(fileURLWithPath: path), team: nil, bundled: true, kind: .surfaces)
        let model = Form(), context = BrowserScreenContext(kind: "onboarding", model: Form())
        let shared = BrowserScreenContext(kind: "onboarding", model: model)
        BrowserScreenContext.contexts[shared.id] = shared
        defer { BrowserScreenContext.contexts.removeValue(forKey: shared.id) }
        let slot = NativeModuleSlot(fallback: NSView(), kind: .surfaces)
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: ["screen": shared.id]))
        XCTAssertTrue(slot.install(library))
        model.email = "preserved@example.com"
        XCTAssertTrue(shared.model === model)
        XCTAssertEqual((shared.model as? Form)?.email, "preserved@example.com")
        XCTAssertNotEqual(shared.id, context.id)
        slot.retire()
    }
}
