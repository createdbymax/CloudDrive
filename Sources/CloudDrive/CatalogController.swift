import Foundation

/// One sequential indexer per destination. Only a completed listing can nominate
/// missing keys; HEAD errors never mean deletion. No cloud objects are modified.
enum CatalogIndexer {
    static func scan(store: CatalogStore, remote: any ObjectInventoryRemote, fresh: Bool,
                     progress: @Sendable (CatalogSummary) async -> Void = { _ in }) async throws {
        var scan = try await store.beginScan(fresh: fresh)
        while true {
            try Task.checkCancellation()
            let page = try await remote.list(token: scan.token)
            try Task.checkCancellation()
            try await store.commit(page: page, scan: scan)
            await progress(try await store.summary())
            guard let token = page.nextToken else { break }
            scan = CatalogScan(id: scan.id, token: token)
        }
        // Circuit breaker: never publish a mass disappearance from a single pass.
        let summary = try await store.summary()
        let initial = try await store.missingCandidates(scanID: scan.id)
        if initial.count == 100 && summary.count > 0 {
            // Check whether this is >25% of the inventory before allowing deletion.
            var missingCount = initial.count, last = initial.last!.0
            while missingCount <= max(100, summary.count / 4) {
                let page = try await store.missingCandidates(scanID: scan.id, after: last)
                if page.isEmpty { break }
                missingCount += page.count; last = page.last!.0
            }
            if missingCount > max(100, summary.count / 4) {
                guard try await store.largeMissingIsConfirmed(scanID:scan.id) else { throw CatalogFailure.largeChange }
            }
        }
        var after: Int64 = 0
        while true {
            try Task.checkCancellation()
            let candidates = try await store.missingCandidates(scanID: scan.id, after: after)
            if candidates.isEmpty { break }
            for (id, key) in candidates {
                try Task.checkCancellation()
                if try await remote.isMissing(key: key) {
                    try Task.checkCancellation()
                    try await store.confirmMissing(id: id, scanID: scan.id)
                }
                after = id
            }
        }
        try await store.finish(scanID: scan.id)
        await progress(try await store.summary())
    }
}

@MainActor final class CatalogController: ObservableObject {
    var namespaceSearch: (@MainActor (CatalogQuery) async throws -> [CatalogObject]?)?
    func namespaceChanged() { revision += 1; results = []; queryGeneration = UUID() }
    @Published private(set) var summary = CatalogSummary()
    @Published private(set) var scanning = false
    @Published private(set) var loading = false
    @Published private(set) var message = ""
    @Published private(set) var results: [CatalogObject] = []
    @Published private(set) var searching = false
    @Published private(set) var searchError = ""
    @Published private(set) var revision = 0
    @Published private(set) var automaticEnabled = false
    @Published private(set) var automaticPaused = false
    @Published private(set) var automaticStatus = ""
    private var automaticTask: Task<Void,Never>?
    private let automaticInterval: Duration
    private let reconciliationInterval: TimeInterval?
    private let minimumScanSpacing: TimeInterval
    private var lastScanAttempt = Date.distantPast
    private var automaticRetryAt = Date.distantPast
    private var automaticFailures = 0
    private var lastChangeProgress = Date.distantPast
    private var forceFreshScan = false
    private let root: URL
    private let makeRemote: @Sendable (Connection) -> any ObjectInventoryRemote
    private var destination: String?
    private var store: CatalogStore?
    private var connection: Connection?
    private var epoch = UUID()
    private var scanTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var queryGeneration = UUID()
    init(root: URL, automaticInterval: Duration = .seconds(2), reconciliationInterval: TimeInterval? = nil, minimumScanSpacing: TimeInterval = 5, makeRemote: @escaping @Sendable (Connection) -> any ObjectInventoryRemote = { S3InventoryRemote(connection: $0) }) {
        self.root = root; self.makeRemote = makeRemote; self.automaticInterval = automaticInterval
        self.reconciliationInterval = reconciliationInterval; self.minimumScanSpacing = max(0.01,minimumScanSpacing)
    }
    deinit { scanTask?.cancel(); loadTask?.cancel(); automaticTask?.cancel() }

    func configure(connection: Connection) {
        self.connection = connection
        guard destination != connection.fingerprint else { return }
        scanTask?.cancel(); loadTask?.cancel(); scanTask = nil
        epoch = UUID(); queryGeneration = UUID(); destination = connection.fingerprint; lastScanAttempt = .distantPast; automaticRetryAt = .distantPast; automaticFailures = 0; forceFreshScan = false
        results = []; summary = CatalogSummary(); scanning = false; message = ""; searchError = ""; loading = true
        guard !connection.endpoint.isEmpty, !connection.bucket.isEmpty, !connection.prefix.isEmpty else {
            store = nil; loading = false; message = "Load your connection in Settings to index and search this drive."; revision += 1
            return
        }
        let current = epoch
        let store = CatalogStore(directory: root.appendingPathComponent("Catalog/" + connection.fingerprint), fingerprint: connection.fingerprint, prefix: connection.prefix)
        self.store = store
        loadTask = Task { [weak self] in
            do {
                let summary = try await store.summary()
                guard let self, self.epoch == current, !Task.isCancelled else { return }
                self.summary = summary; self.loading = false; self.revision += 1
            } catch {
                guard let self, self.epoch == current, !Task.isCancelled else { return }
                self.loading = false; self.message = "The saved search catalog could not be opened. Check local storage and permissions."
            }
        }
    }
    func enableAutomaticUpdates() {
        automaticEnabled = true
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.automaticTick()
                guard let interval = self?.automaticInterval else { return }
                do { try await Task.sleep(for:interval) } catch { return }
            }
        }
    }
    func stopAutomaticUpdates() {
        automaticTask?.cancel(); automaticTask = nil; automaticEnabled = false
    }
    func recordUploadHints(_ hints: [UploadCatalogHint]) async throws {
        if let loadTask { await loadTask.value }
        guard let store else { throw CatalogFailure.storage }
        let current = epoch
        try await store.recordUploadHints(hints)
        guard current == epoch else { throw CatalogFailure.superseded }
        automaticRetryAt = .distantPast
    }
    func workerCursor() async throws -> CatalogWorkerCursor {
        if let loadTask { await loadTask.value }
        guard let store else { throw CatalogFailure.storage }
        return try await store.workerCursor()
    }
    @discardableResult
    func recordWorkerChanges(_ data: Data, after: Int64) async throws -> Bool {
        guard let store else { throw CatalogFailure.storage }
        let page = try JSONDecoder().decode(WorkerMetadataChanges.self,from:data)
        try await store.recordWorkerChanges(page,after:after)
        return page.hasMore
    }
    func requireReconciliation() async throws {
        guard let store else { throw CatalogFailure.storage }
        try await store.requireReconciliation()
    }
    private func publishChangeProgress(store:CatalogStore,epoch:UUID) async {
        guard self.epoch == epoch, !Task.isCancelled, Date().timeIntervalSince(lastChangeProgress) >= 0.25 else { return }
        lastChangeProgress = Date()
        if let summary = try? await store.summary() {
            guard self.epoch == epoch, !Task.isCancelled else { return }
            update(summary:summary,epoch:epoch)
            automaticStatus = "Updating recent file changes…"
        }
    }
    private func automaticTick() async {
        guard automaticEnabled, !automaticPaused, !loading, let store, let connection else { return }
        guard (try? connection.validate()) != nil else { return }
        guard Date() >= automaticRetryAt else { return }
        let current = epoch
        do {
            let pending = try await store.pendingChanges(limit:1)
            var changed = false
            if !pending.isEmpty {
                let remote = makeRemote(connection); defer { remote.close() }
                changed = try await CatalogChangeReconciler.drain(store:store,remote:remote) { [weak self] in
                    await self?.publishChangeProgress(store:store,epoch:current)
                }
            }
            automaticFailures = 0
            guard current == epoch, !Task.isCancelled else { return }
            if changed {
                let summary = try await store.summary()
                guard current == epoch, !Task.isCancelled else { return }
                update(summary:summary,epoch:current)
                automaticStatus = "Recent changes indexed automatically."
            }
            let needed = try await store.needsReconciliation()
            let interval: TimeInterval = reconciliationInterval ?? (summary.count < 10_000 ? 30 : summary.count < 100_000 ? 120 : summary.count < 1_000_000 ? 900 : 3600)
            let sinceAttempt = Date().timeIntervalSince(lastScanAttempt)
            if !scanning, sinceAttempt >= minimumScanSpacing, (needed || summary.lastCompleted.map { Date().timeIntervalSince($0) >= interval } ?? true) {
                refresh(automatic:true)
            }
        } catch {
            guard current == epoch, !Task.isCancelled else { return }
            // Some keys may have succeeded before a different key failed.
            if let summary = try? await store.summary() { update(summary:summary,epoch:current) }
            guard current == epoch, !Task.isCancelled else { return }
            automaticFailures = min(automaticFailures+1,6)
            automaticRetryAt = Date().addingTimeInterval(min(60,Double(1 << automaticFailures)))
            automaticStatus = "Some changes are waiting for a metadata check. Automatic updates will retry."
        }
    }
    func refresh(fresh: Bool = false, automatic: Bool = false) {
        if !automatic { automaticPaused = false; automaticRetryAt = .distantPast; if automaticEnabled { enableAutomaticUpdates() } }

        guard !loading, !scanning, let store, let connection else { return }
        do { try connection.validate() } catch { message = "Load a valid connection in Settings before indexing. Saved results can still be searched."; return }
        let current = epoch
        let fresh = fresh || forceFreshScan; forceFreshScan = false
        lastScanAttempt = Date()
        scanning = true; message = "Refreshing file names and metadata. File contents are not downloaded."
        scanTask = Task { [weak self] in
            let remote = self?.makeRemote(connection) ?? S3InventoryRemote(connection: connection)
            defer { remote.close() }
            do {
                try await CatalogIndexer.scan(store: store, remote: remote, fresh: fresh) { [weak self] summary in
                    await self?.update(summary: summary, epoch: current)
                }
                guard let self, self.epoch == current else { return }
                self.message = "Inventory refreshed. Search file names and paths even while offline."
            } catch {
                guard let self, self.epoch == current else { return }
                if case CatalogFailure.http(400) = error { self.forceFreshScan = true }
                if case CatalogFailure.invalidInventory = error { self.forceFreshScan = true }
                self.lastScanAttempt = Date()
                if Task.isCancelled { self.message = "Indexing paused. Saved files remain searchable; Refresh resumes saved listing progress." }
                else if case CatalogFailure.superseded = error { self.message = "New file changes arrived. Automatic indexing will continue with the latest metadata." }
                else { self.message = (error as? CatalogFailure)?.localizedDescription ?? "Inventory refresh could not finish. Saved results remain searchable; check your connection and retry." }
            }
            guard let self, self.epoch == current else { return }
            self.scanning = false; self.revision += 1
        }
    }
    private func update(summary: CatalogSummary, epoch: UUID) {
        guard self.epoch == epoch else { return }
        self.summary = summary; revision += 1
    }
    func pause() { automaticPaused = true; automaticTask?.cancel(); automaticTask = nil; scanTask?.cancel(); automaticStatus = "Automatic indexing paused. Refresh index resumes updates." }
    /// Independent readers (such as the global search panel) must not replace the
    /// inventory window's query, results or selection. The same local store and
    /// cancellation budget are shared, without starting a remote operation.
    func searchSnapshot(_ query: CatalogQuery) async throws -> [CatalogObject] {
        if let namespaceSearch, let found = try await namespaceSearch(query) { return found }
        let current = epoch
        if let loadTask { await loadTask.value }
        try Task.checkCancellation()
        guard current == epoch else { throw CatalogFailure.superseded }
        guard let store else { return [] }
        let found = try await store.search(query)
        try Task.checkCancellation()
        guard current == epoch else { throw CatalogFailure.superseded }
        return found
    }
    func search(_ query: CatalogQuery) async {
        let generation = UUID(), current = epoch
        queryGeneration = generation; searchError = ""; searching = true
        do {
            try await Task.sleep(for: .milliseconds(45))
            let found = try await searchSnapshot(query)
            guard !Task.isCancelled, current == epoch, generation == queryGeneration else { return }
            results = found; searching = false
        } catch {
            guard !Task.isCancelled, current == epoch, generation == queryGeneration else { return }
            results = []; searching = false
            searchError = (error as? CatalogFailure)?.localizedDescription ?? "Local search is unavailable. Check local storage and retry."
        }
    }
}
