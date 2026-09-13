import AppKit
import SwiftUI
import AVFoundation
import WebKit

@MainActor final class PermissionSettingsModel: ObservableObject, PermissionsPresentation {
    static let shared = PermissionSettingsModel()
    @Published var selectedProfile = SiteAppConfiguration.current?.profile ?? "default" { didSet { selectedOrigin = nil; refresh() } }
    @Published var selectedOrigin: String? { didSet { refreshControls() } }
    @Published private(set) var sites: [String] = []
    @Published private(set) var controls: [PermissionControl] = []
    @Published private(set) var error: String?
    private let store: SitePermissionStore
    private var timer: Timer?
    var profiles: [SurfaceProfile] {
        Profile.all.filter { SiteAppConfiguration.current == nil || $0.id == selectedProfile }.map {
            SurfaceProfile(id: $0.id, name: $0.name, tint: $0.tint, icon: $0.icon, avatar: $0.character)
        }
    }
    init(store: SitePermissionStore = .shared) { self.store = store }
    func start() {
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }
    func show(_ engine: EngineView?) {
        if let engine { selectedProfile = engine.profileId; selectedOrigin = SitePermissionKey.origin(engine.webView.url) }
        start()
    }
    func refresh() {
        let saved = store.entries.keys.filter { $0.profile == selectedProfile }.map(\.origin)
        let open = EngineView.live.values.filter { $0.profileId == selectedProfile }.compactMap { SitePermissionKey.origin($0.webView.url) }
        let extra = selectedOrigin.map { [$0] } ?? []
        sites = Array(Set(saved + open + extra)).sorted()
        if selectedOrigin == nil { selectedOrigin = sites.first }
        refreshControls()
    }
    private func engines() -> [EngineView] {
        guard let selectedOrigin else { return [] }
        return EngineView.live.values.filter { $0.profileId == selectedProfile && SitePermissionKey.origin($0.webView.url) == selectedOrigin }
    }
    private func refreshControls() {
        guard let origin = selectedOrigin else { controls = []; return }
        let tabs = engines()
        controls = SitePermissionKey.kinds.map { kind in
            let status: String
            if kind == "notifications" {
                status = SiteAppConfiguration.current == nil ? "Available in saved apps; Web Push is not supported." : "macOS notification settings also apply."
            } else {
                switch AVCaptureDevice.authorizationStatus(for: kind == "camera" ? .video : .audio) {
                case .denied, .restricted: status = "Blocked in macOS Privacy & Security settings."
                case .notDetermined: status = "macOS will also ask before first use."
                default: status = "macOS access is allowed."
                }
            }
            let active = tabs.contains { kind == "camera" ? $0.webView.cameraCaptureState != .none : kind == "microphone" && $0.webView.microphoneCaptureState != .none }
            return PermissionControl(id: kind, title: kind.capitalized, choice: store.decision(profile: selectedProfile, origin: origin, kind: kind),
                status: status, active: active, available: kind != "notifications" || SiteAppConfiguration.current != nil)
        }
    }
    func set(_ kind: String, choice: String) {
        guard let origin = selectedOrigin else { return }
        do {
            try store.set(profile: selectedProfile, origin: origin, kinds: [kind], decision: choice)
            if choice != "allow" { stop(kind) }
            error = nil; refresh()
        } catch { self.error = "Couldn’t save this permission. Please try again." }
    }
    func resetSite() {
        guard let origin = selectedOrigin else { return }
        do {
            try store.set(profile: selectedProfile, origin: origin, kinds: SitePermissionKey.kinds, decision: "ask")
            stop("camera"); stop("microphone"); error = nil; refresh()
        } catch { self.error = "Couldn’t reset permissions." }
    }
    func resetProfile() {
        do {
            try store.reset(profile: selectedProfile)
            for engine in EngineView.live.values where engine.profileId == selectedProfile { engine.stopMediaCapture() }
            error = nil; refresh()
        } catch { self.error = "Couldn’t reset permissions." }
    }
    func stop(_ kind: String) {
        for engine in engines() {
            if kind == "camera" { engine.webView.setCameraCaptureState(.none, completionHandler: nil) }
            if kind == "microphone" { engine.webView.setMicrophoneCaptureState(.none, completionHandler: nil) }
        }
        refreshControls()
    }
}

@MainActor final class SitePermissionsWindow: NSObject {
    static let shared = SitePermissionsWindow()
    private var window: NSWindow?
    @objc func show(_ sender: Any? = nil) {
        let id = (NSApp.delegate as? AppDelegate)?.currentWebviewId
        open(engine: id.flatMap { EngineView.live[$0] })
    }
    func open(engine: EngineView?) {
        PermissionSettingsModel.shared.show(engine)
        if SiteAppConfiguration.current == nil { SettingsWindow.shared.show(select: "websites"); return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Website Permissions"
            window.contentView = NSHostingView(rootView: LiveBrowserScreen(kind: "permissions", model: PermissionSettingsModel.shared))
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
