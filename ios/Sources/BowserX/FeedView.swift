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
    private var lastCount = 0
    private var ended = false   // a load added nothing = true feed end

    func load(route: String) async {
        loading = response == nil
        error = nil
        do {
            let next = try await BrainClient.screen(route: route, want: want)
            response = next
            lastCount = next.data["tweets"]?.arrayValue?.count ?? 0
            ended = false
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Called when the last row appears — deepen the feed. Stops only when a
    /// load adds nothing new (true feed end), not when a fetch merely falls
    /// short of `want` (a timeout shortfall stays resumable).
    func loadMore(route: String, currentCount: Int) async {
        guard !loadingMore, !ended else { return }
        loadingMore = true
        want += page
        do {
            let next = try await BrainClient.screen(route: route, want: want)
            let count = next.data["tweets"]?.arrayValue?.count ?? 0
            if count <= lastCount {
                ended = true            // no growth: the feed gave all it has
            } else {
                response = next
                lastCount = count
            }
        } catch {
            // Transient failure — keep what we have and stay resumable.
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
