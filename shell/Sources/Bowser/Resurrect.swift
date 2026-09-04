import AppKit
import WebKit

/// The freeze-frame trick (bowser-browser-9qr): the shell continuously
/// snapshots the active tab (every ~5s + after tab switches) to
/// ~/.bowser/resurrect.jpg. A fresh instance shows that frame as a
/// full-window overlay from its very first paint, and crossfades to the
/// live page once the restored active tab finishes loading — an engine
/// death looks like a blink, not a blank window.
///
/// Continuous capture (not a prepare-to-die handshake) means CRASHES get
/// the same treatment as planned rolls: whatever frame exists is at most a
/// few seconds stale. WKWebView.takeSnapshot is the capture path — unlike
/// CGWindowListCreateImage it needs no screen-recording permission and
/// captures the out-of-process web content reliably.
@MainActor
enum ResurrectFrame {
    static let freshnessSeconds: TimeInterval = 120

    static var fileURL: URL {
        BowserPaths.home
            .appendingPathComponent("resurrect.jpg")
    }

    /// Only a RECENT past is worth showing — a frame from hours ago
    /// (manual quit, closed laptop) would flash misleading content.
    static func shouldShow(fileDate: Date?, now: Date = Date()) -> Bool {
        guard let fileDate else { return false }
        return now.timeIntervalSince(fileDate) < freshnessSeconds
    }

    static func loadImage() -> NSImage? {
        let path = fileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              shouldShow(fileDate: attrs[.modificationDate] as? Date)
        else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private static var capturing = false

    /// Snapshot the webview and persist it. Encode + write happen off the
    /// main thread — this runs every few seconds and must never jank.
    static func capture(_ webView: WKWebView) {
        guard !capturing, webView.window != nil else { return }
        capturing = true
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated { capturing = false }
            guard let image, let tiff = image.tiffRepresentation else { return }
            let url = fileURL
            DispatchQueue.global(qos: .utility).async {
                guard let rep = NSBitmapImageRep(data: tiff),
                      let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                else { return }
                try? jpeg.write(to: url, options: .atomic)
            }
        }
    }
}

/// The overlay itself: swallows its first click (dismissing) so the user
/// can't interact with a frame of the past.
final class ResurrectOverlayView: NSImageView {
    var onDismiss: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}
