import AppKit
import WebKit

/// Downloads and pending WebKit completions outlive their tab and controller.
@MainActor final class NativeDownloads: NSObject, WKDownloadDelegate {
    static let shared = NativeDownloads()
    private struct Record {
        let tab: UInt64
        let profile: String
        let download: WKDownload?
        var destination: URL?
        var suggested = ""
        var completion: ((URL?) -> Void)?
    }
    var destinationDirectory: URL?
    private var records: [String: Record] = [:]
    var snapshot: [[String: Any]] {
        records.keys.sorted().map { id in
            let r = records[id]!
            return ["id":id, "tab":r.tab, "profile":r.profile, "suggested":r.suggested, "awaiting_destination":r.completion != nil]
        }
    }
    func attach(_ download: WKDownload, tab: UInt64, profile: String) {
        records[UUID().uuidString] = Record(tab: tab, profile: profile, download: download)
        download.delegate = self
    }
    func stage(id: String, tab: UInt64, profile: String, suggested: String, completion: @escaping (URL?) -> Void) {
        if records[id] == nil { records[id] = Record(tab: tab, profile: profile, download: nil) }
        records[id]?.suggested = suggested
        records[id]?.completion = completion
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let id = records.first(where: { $0.value.download === download })?.key, let record = records[id] else { completionHandler(nil); return }
        stage(id: id, tab: record.tab, profile: record.profile, suggested: suggestedFilename, completion: completionHandler)
        if BrainBridge.shared.resources.shouldCoordinate {
            if !BrainBridge.shared.resources.request(["action":"download_destination", "download":id]) {
                records[id]?.completion = nil; completionHandler(nil)
            }
        } else {
            _ = choose(["download":id, "profile":record.profile, "filename":Self.safeFilename(suggestedFilename)])
        }
    }
    func choose(_ command: [String: Any]) -> Bool {
        guard let id = command["download"] as? String, var record = records[id],
              command["profile"] as? String == record.profile, let completion = record.completion,
              let filename = command["filename"] as? String, filename == Self.safeFilename(filename) else { return false }
        let destination = Self.uniqueURL(filename, directory: destinationDirectory, reserved: Set(records.values.compactMap(\.destination)))
        record.completion = nil; record.destination = destination; records[id] = record
        BrainBridge.shared.send(["op":"event", "event":"download", "download":id,
                                 "webview":record.tab, "profile":record.profile, "state":"started", "filename":destination.lastPathComponent])
        completion(destination)
        return true
    }
    func downloadDidFinish(_ download: WKDownload) { finish(download, state: "finished", error: nil) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, state: "failed", error: error.localizedDescription)
    }
    private func finish(_ download: WKDownload, state: String, error: String?) {
        guard let id = records.first(where: { $0.value.download === download })?.key,
              let record = records.removeValue(forKey: id) else { return }
        var message: [String: Any] = ["op":"event", "event":"download", "download":id,
            "webview":record.tab, "profile":record.profile, "state":state]
        if let error { message["error"] = error }
        BrainBridge.shared.send(message)
    }
    func cancelDestination(_ id: String) {
        guard let record = records.removeValue(forKey: id) else { return }
        record.completion?(nil)
    }
    static func safeFilename(_ suggested: String) -> String {
        let value = (suggested.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
        return value.isEmpty || value == "." || value == ".." ? "download" : String(value.prefix(180))
    }
    static func uniqueURL(_ suggested: String, directory: URL? = nil, reserved: Set<URL> = []) -> URL {
        let dir = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var url = dir.appendingPathComponent(safeFilename(suggested))
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while reserved.contains(url) || FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
