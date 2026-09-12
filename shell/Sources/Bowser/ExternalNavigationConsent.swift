import AppKit

/// Website navigation never launches another application without a user decision.
@MainActor
final class ExternalNavigationConsent {
    private(set) var pending = false

    func request(url: URL, source: String, window: NSWindow) {
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let name = FileManager.default.displayName(atPath: application.path)
        request(url: url, present: { completion in
            let alert = NSAlert()
            alert.messageText = "Open \(name)?"
            alert.informativeText = "\(source) wants to open a link in \(name)."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open")
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertSecondButtonReturn)
            }
        }, open: { NSWorkspace.shared.open($0) })
    }

    func request(url: URL, present: (@escaping @MainActor (Bool) -> Void) -> Void,
                 open: @escaping @MainActor (URL) -> Void) {
        guard !pending else { return }
        pending = true
        present { [weak self] approved in
            guard let self, self.pending else { return }
            self.pending = false
            if approved { open(url) }
        }
    }
}
