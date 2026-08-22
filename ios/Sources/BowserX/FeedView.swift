import SwiftUI

/// Renders a screen declaration + its data as a native list with infinite
/// scroll: as the reader nears the bottom, `want` climbs and the brain
/// scroll-accumulates deeper into the timeline (BowserBrain.XFeed).
@MainActor
final class FeedModel: ObservableObject {
    @Published var response: SDUIResponse?
    @Published var error: String?
    @Published var loading = false

    private var want = 15
    private let page = 15
    private var loadingMore = false

    func load(route: String) async {
        loading = response == nil
        error = nil
        do {
            response = try await BrainClient.screen(route: route, want: want)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Called when the last row appears — deepen the feed.
    func loadMore(route: String, currentCount: Int) async {
        guard !loadingMore, want <= currentCount else { return }
        loadingMore = true
        want += page
        do {
            response = try await BrainClient.screen(route: route, want: want)
        } catch {
            // Keep what we have; a failed deepen shouldn't blank the feed.
        }
        loadingMore = false
    }
}

struct FeedView: View {
    let route: String
    @StateObject private var model = FeedModel()

    var body: some View {
        Group {
            if let response = model.response, let list = response.screen.list {
                let items = response.items(for: list)
                List(Array(items.enumerated()), id: \.offset) { index, item in
                    SDUINodeView(node: list.item, item: item)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .onAppear {
                            if index == items.count - 3 {
                                Task { await model.loadMore(route: route, currentCount: items.count) }
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
        .navigationTitle(model.response?.screen.title ?? route)
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.response == nil { await model.load(route: route) } }
    }
}
