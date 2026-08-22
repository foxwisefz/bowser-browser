import SwiftUI

/// Renders a screen declaration + its data as a native list. This is a
/// generic SDUI screen host — it knows nothing about tweets specifically;
/// it renders whatever declaration the brain sends, bound to whatever data.
@MainActor
final class FeedModel: ObservableObject {
    @Published var response: SDUIResponse?
    @Published var error: String?
    @Published var loading = false

    func load(route: String) async {
        loading = true
        error = nil
        do {
            response = try await BrainClient.screen(route: route)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct FeedView: View {
    let route: String
    @StateObject private var model = FeedModel()

    var body: some View {
        Group {
            if let response = model.response, let list = response.screen.list {
                List(Array(response.items(for: list).enumerated()), id: \.offset) { _, item in
                    SDUINodeView(node: list.item, item: item)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
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
