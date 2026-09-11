import SwiftUI

/// A timeline datum with a STABLE identity (the tweet id), so SwiftUI tracks
/// rows by tweet — not array position. Without this, a re-sorted or extended
/// feed (like the likes-ranked "Big" wall) shows the same tweet as a "new"
/// row at a new index, which reads as repeats.
struct FeedItem: Identifiable {
    let id: String
    let value: JSONValue
}

@MainActor
final class FeedModel: ObservableObject {
    @Published var screen: SDUIScreen?
    @Published var items: [FeedItem] = []
    @Published var error: String?
    @Published var loading = false

    private var want = 15
    private let page = 15
    private var loadingMore = false
    private var ended = false

    func load(route: String) async {
        loading = items.isEmpty
        error = nil
        do {
            let r = try await BrainClient.screen(route: route, want: want)
            apply(r)
            ended = false
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func loadMore(route: String) async {
        guard !loadingMore, !ended else { return }
        loadingMore = true
        want += page
        do {
            let before = items.count
            let r = try await BrainClient.screen(route: route, want: want)
            apply(r)
            if items.count <= before { ended = true }   // true feed-end
        } catch {
            // transient — stay resumable
        }
        loadingMore = false
    }

    private func apply(_ r: SDUIResponse) {
        screen = r.screen
        guard let list = r.screen.list else { items = []; return }
        var seen = Set<String>()
        items = r.items(for: list).enumerated().compactMap { index, value in
            let id = value.resolve("id")?.stringValue
                ?? value.resolve("permalink")?.stringValue
                ?? "row-\(index)"
            guard seen.insert(id).inserted else { return nil }   // dedup by identity
            return FeedItem(id: id, value: value)
        }
    }
}

struct FeedView: View {
    let route: String
    @StateObject private var model = FeedModel()

    var body: some View {
        Group {
            if let screen = model.screen, let list = screen.list {
                List(model.items) { item in
                    SDUINodeView(node: list.item, item: item.value)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .onAppear {
                            if item.id == model.items.suffix(3).first?.id {
                                Task { await model.loadMore(route: route) }
                            }
                        }
                }
                .listStyle(.plain)
                .refreshable { await model.load(route: route) }
            } else if model.loading {
                ProgressView("Loading \(route)…")
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Can't reach the brain", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await model.load(route: route) } }
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle(model.screen?.title ?? route)
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.items.isEmpty { await model.load(route: route) } }
    }
}
