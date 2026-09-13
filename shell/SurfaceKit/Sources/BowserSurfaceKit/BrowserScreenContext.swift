import AppKit
import SwiftUI
import Combine

/// Stable state shared by host services and successive signed screen renderers.
@MainActor public final class BrowserScreenContext: ObservableObject {
    public static var contexts: [String: BrowserScreenContext] = [:]
    public let id = UUID().uuidString
    public let kind: String
    public let model: AnyObject
    @Published public var values: [String: Any] = [:]
    private var observation: AnyCancellable?
    public init<Model: ObservableObject>(kind: String, model: Model) where Model.ObjectWillChangePublisher == ObservableObjectPublisher {
        self.kind = kind; self.model = model
        observation = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }
    public func binding<Value>(_ key: String, default value: Value) -> Binding<Value> {
        Binding(get: { self.values[key] as? Value ?? value }, set: { self.values[key] = $0 })
    }
}

@MainActor public protocol OnboardingPresentation: AnyObject {
    var email: String { get set }
    var acceptedTerms: Bool { get set }
    var trainingConsent: Bool { get set }
    var submitting: Bool { get }
    var error: String? { get }
    var completed: Bool { get }
    var termsURL: URL { get }
    var canSubmit: Bool { get }
    func submit() async
    func finish()
}
