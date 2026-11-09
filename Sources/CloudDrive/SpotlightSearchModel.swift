import Foundation
import Combine

/// Query state belongs to a search surface, rather than to the shared indexer.
@MainActor final class SpotlightSearchModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            invalidate()
        }
    }
    @Published private(set) var results: [CatalogObject] = []
    @Published private(set) var searching = false
    @Published private(set) var error = ""
    @Published var selectedID: Data?

    var selectedResult: CatalogObject? { results.first { $0.id == selectedID } }
    private var generation = UUID()
    private var scope = ""
    private let debounce: Duration
    private let performSearch: @MainActor (CatalogQuery) async throws -> [CatalogObject]

    convenience init(catalog: CatalogController) {
        self.init { query in try await catalog.searchSnapshot(query) }
    }

    init(debounce: Duration = .milliseconds(90), search: @escaping @MainActor (CatalogQuery) async throws -> [CatalogObject]) {
        self.debounce = debounce
        self.performSearch = search
    }

    /// Call from a SwiftUI task keyed by query, connection fingerprint and catalog
    /// revision. Cancellation propagates into SQLite's bounded local read.
    func search(scope newScope: String = "") async {
        if scope != newScope { invalidate(); scope = newScope }
        let current = UUID(), text = query
        generation = current
        error = ""; searching = true
        do {
            try await Task.sleep(for: debounce)
            let found = try await performSearch(CatalogQuery(text: text, limit: 6))
            guard generation == current, query == text, !Task.isCancelled else { return }
            let nextSelection = CatalogSelection.reconcile(selectedID, previous: results, updated: found)
            results = found
            selectedID = nextSelection
            searching = false
        } catch {
            guard generation == current, query == text else { return }
            searching = false
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            results = []; selectedID = nil
            self.error = (error as? CatalogFailure)?.localizedDescription ?? "Local search is unavailable. Check local storage and retry."
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { selectedID = nil; return }
        let index = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : 0)
        let next = ((index + offset) % results.count + results.count) % results.count
        selectedID = results[next].id
    }

    func reset() {
        query = ""
        invalidate()
    }

    private func invalidate() {
        generation = UUID()
        results = []; selectedID = nil; error = ""; searching = false
    }
}
