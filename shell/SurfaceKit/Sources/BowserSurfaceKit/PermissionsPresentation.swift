import Foundation

public struct PermissionControl: Identifiable {
    public let id: String
    public let title: String
    public let choice: String
    public let status: String
    public let active: Bool
    public let available: Bool
    public init(id: String, title: String, choice: String, status: String, active: Bool, available: Bool) {
        self.id = id; self.title = title; self.choice = choice; self.status = status; self.active = active; self.available = available
    }
}
@MainActor public protocol PermissionsPresentation: AnyObject {
    var profiles: [SurfaceProfile] { get }
    var selectedProfile: String { get set }
    var sites: [String] { get }
    var selectedOrigin: String? { get set }
    var controls: [PermissionControl] { get }
    var error: String? { get }
    func set(_ kind: String, choice: String)
    func resetSite()
    func resetProfile()
    func stop(_ kind: String)
}
