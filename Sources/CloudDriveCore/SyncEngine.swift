import Foundation

public struct SyncEngineStatus: Codable, Equatable, Sendable {
    public var phase: String
    public var pending: Int
    public var attention: Int
    public var localRevision: Int64
    public var publishedRevision: Int64
    public var dirtyBytes: Int64
    public var cleanCacheBytes: Int64
    public var pinnedBytes: Int64
    public var lastError: String?
    public var activeOperationID: UUID?
    public var retainedCleanBytes: Int64 = 0
    public var requestedPins: Int = 0
    public var completedPins: Int = 0
    public var pinAttention: Int = 0
    public var pinRequestedBytes: Int64 = 0
    public var pinCompletedBytes: Int64 = 0
    public var uploadBytesPerSecond: Double? = nil
}

/// One owner admits local transactions; provider work runs only after admission.
/// Store actor transactions contain no network requests. Each remote operation has
/// durable intent and receipts, so a restarted owner reconciles before retrying.
public actor SyncEngine {
    public let store: NamespaceStore
    public let content: ContentStore
    public let cache: RangeCache
    private let remote: any StorageRemote
    private let uploadBytesPerSecond: @Sendable () -> Double?
    private let prefix: String
    private let mode: NamespaceStorageMode
    private let managedUploadConcurrency: Int
    private let usesAdmissionFence: Bool
    private var processing = false
    private var preparingAhead = false
    private struct PendingPayload {
        let snapshotID: UUID?
        var waiters: [CheckedContinuation<StorageObject, Error>] = []
    }
    private var pendingPayloads: [UUID: PendingPayload] = [:]
    private var pauseRequested = false
    private enum Control: Error { case pauseRequested }
    private var activeOperationID: UUID?
    private var lastManagedWrite: [NodeID: ContinuousClock.Instant] = [:]

    private func noteManagedWrite(_ nodeID: NodeID) {
        guard mode == .managed else { return }
        lastManagedWrite[nodeID] = .now
    }

    private var retryAfter: ContinuousClock.Instant?
    private var backgroundReclaimAfter: ContinuousClock.Instant?
    private var pinRetryAfter: ContinuousClock.Instant?
    private var lastError: String?

    // Managed mutations reconcile immutable objects and conditional HEAD writes on replay.
    // Compatible-mode path mutations keep their explicit recovery policy.
    private func isRetryableManagedError(_ code: String?) -> Bool {
        mode == .managed && (code == "offline" || code == "unknownOutcome" || code == "busy" || code == "remoteUnavailable")
    }

    private func recordFailure(_ error: Error, operation: NamespaceOperation) async throws {
        let code = classify(error)
        lastError = code
        let retryable = isRetryableManagedError(code)
        if retryable {
            let seconds = 1 << min(5, max(0, operation.attemptCount))
            retryAfter = .now.advanced(by: .seconds(seconds))
        }
        try await store.setOperationState(operation.id, state: retryable ? .pending : .attention, errorCode: code)
    }
    private var leases: [UUID: NamespaceNode] = [:]
    private var publisher: ManagedManifestPublisher?
    private var pendingPins: Set<UUID> = []
    private var pinRunner: Task<Void, Never>?
    private struct RelocationManifest: Codable {
        var version = 1
        var operationID: UUID
        var source: String
        var destination: String
        var cursor: String?
        var inventoryComplete = false
        var listingFinished: Bool? = nil
        var pages: [UUID] = []
    }
    private struct RelocationObject: Codable { var source: StorageObject; var destination: String }

    public init(store: NamespaceStore, content: ContentStore, cache: RangeCache, remote: any StorageRemote,
                prefix: String, mode: NamespaceStorageMode = .compatible, managedUploadConcurrency: Int = 8,
                uploadBytesPerSecond: @escaping @Sendable () -> Double? = { nil }) {
        self.store = store; self.content = content; self.cache = cache; self.remote = remote
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")); self.mode = mode
        self.managedUploadConcurrency = min(8, max(1, managedUploadConcurrency))
        usesAdmissionFence = mode == .managed && store.admissionFenceDirectory.map {
            CoreFileIO.sameAPFSVolume(content.directory.appendingPathComponent("extents"), $0)
                && CoreFileIO.sameAPFSVolume(content.directory.appendingPathComponent("snapshots"), $0)
        } == true
    }
    public func retain(node: NamespaceNode) -> UUID { let token = UUID(); leases[token] = node; return token }
    func refreshRetention(token: UUID, node: NamespaceNode) -> Bool {
        guard let held = leases[token], held.id == node.id, held.contentGeneration <= node.contentGeneration,
              held.metadataGeneration <= node.metadataGeneration else { return false }
        leases[token] = node
        return true
    }
    public func release(token: UUID) async {
        guard let held = leases.removeValue(forKey: token), held.kind == .file else { return }
        // A read-only close or still-unpublished write ordinarily releases no
        // reclaimable data. Only run the full proof and sweep when the departed
        // lease could have protected a retired generation of this file.
        guard (try? await store.closeMayReleaseSnapshot(held)) != false else { return }
        // A Finder close releases its local generation immediately; the sync pass
        // retires remote writeback groups after publication independently of close.
        try? await reclaimPublishedLocalData(includingRemote: false)
    }
    public func read(nodeID: NodeID, offset: Int64, length: Int) async throws -> Data {
        try await read(node: store.node(nodeID), offset: offset, length: length)
    }
    public func read(node: NamespaceNode, offset: Int64, length: Int) async throws -> Data {
        try await readValue(node: node, offset: offset, length: length, requireResident: false)
    }
    private func readValue(node: NamespaceNode, offset: Int64, length: Int, requireResident: Bool) async throws -> Data {
        guard node.kind == .file else { throw NamespaceFailure.isDirectory }
        guard offset >= 0, length >= 0, length <= 8 * 1024 * 1024, offset <= Int64.max - Int64(length) else { throw StorageFailure.invalidRange }
        guard offset < node.size, length > 0 else { return Data() }
        let range = offset..<min(node.size, offset + Int64(length))
        if let id = node.stagedSnapshotID {
            do {
                let snapshot = try await content.snapshot(id: id)
                guard snapshot.nodeID == node.id, snapshot.generation == node.contentGeneration, snapshot.size == node.size else { throw StorageFailure.integrity }
                return try await read(snapshot: snapshot, range: range, requireResident: requireResident)
            } catch {
                // A verified cloud generation may have retired its clean local
                // manifest, or a retained resident original may have disappeared.
                // Unpublished generations never receive this fallback.
                guard let published = try await store.publishedLocator(nodeID: node.id, generation: node.contentGeneration) else { throw error }
                let locator = try await content.resolve(published)
                return try await cache.read(nodeID: node.id, generation: node.contentGeneration, locator: locator, range: range, remote: remote, requireResident: requireResident)
            }
        }
        guard var locator = node.backing else { return Data(repeating: 0, count: range.count) }
        locator = try await content.resolve(locator)
        return try await cache.read(nodeID: node.id, generation: node.contentGeneration, locator: locator, range: range, remote: remote, requireResident: requireResident)
    }
    private func read(snapshot: ContentSnapshot, range: Range<Int64>, requireResident: Bool = false) async throws -> Data {
        var data = Data(repeating: 0, count: range.count)
        let holes = try await content.overlay(snapshot: snapshot, range: range, into: &data, remote: requireResident ? nil : remote, prefix: prefix)
        if let source = snapshot.externalSource {
            guard !requireResident else { throw StorageFailure.busy }
            for hole in holes {
                let end = min(hole.upperBound, snapshot.baseReadableSize)
                guard hole.lowerBound < end else { continue }
                let bytes = try source.read(range: hole.lowerBound..<end)
                data.replaceSubrange(Int(hole.lowerBound - range.lowerBound)..<Int(end - range.lowerBound), with: bytes)
            }
        } else if let base = snapshot.base {
            let locator = try await content.resolve(base)
            for hole in holes {
                let end = min(hole.upperBound, snapshot.baseReadableSize)
                guard hole.lowerBound < end else { continue }
                let bytes = try await cache.read(nodeID: snapshot.nodeID, generation: snapshot.generation,
                                                 locator: locator, range: hole.lowerBound..<end, remote: remote, requireResident: requireResident)
                data.replaceSubrange(Int(hole.lowerBound - range.lowerBound)..<Int(end - range.lowerBound), with: bytes)
            }
        }
        return data
    }
    /// Multipart transport parts may be larger than interactive IO chunks. Compose
    /// a bounded part from small validated reads rather than bypassing range limits.
    private func readUploadRange(snapshot: ContentSnapshot, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= snapshot.size, range.count <= 64 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        var result = Data(); result.reserveCapacity(range.count)
        var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(range.upperBound, offset + 8 * 1024 * 1024)
            result.append(try await read(snapshot: snapshot, range: offset..<end)); offset = end
        }
        return result
    }
    // Independent Finder processes may write the same open file concurrently.
    // Capture the prior generation only after earlier writes to this file commit.
    private var mutationWaiters: [NodeID: [CheckedContinuation<Void, Never>]] = [:]
    private func beginMutation(_ id: NodeID) async {
        if mutationWaiters[id] == nil {
            mutationWaiters[id] = []
            return
        }
        await withCheckedContinuation { mutationWaiters[id, default: []].append($0) }
    }
    private func finishMutation(_ id: NodeID) {
        if mutationWaiters[id]?.isEmpty == false { mutationWaiters[id]?.removeFirst().resume() }
        else { mutationWaiters.removeValue(forKey: id) }
    }
    @discardableResult public func write(nodeID: NodeID, offset: Int64, data: Data, operationID: UUID? = nil) async throws -> NamespaceNode {
        await beginMutation(nodeID)
        defer { finishMutation(nodeID) }
        try Task.checkCancellation()
        let payloadChecksum = CoreFileIO.hash(data)
        let fingerprint = try mutationFingerprint(kind: "write", nodeID: nodeID, offset: offset, payloadSHA256: payloadChecksum)
        if let replay = try await replayMutation(operationID, nodeID: nodeID, fingerprint: fingerprint) { return replay }
        let node = try await store.node(nodeID)
        return try await writeValue(node: node, offset: offset, data: data, allowUnlinked: false, operationID: operationID, fingerprint: fingerprint, payloadChecksum: payloadChecksum)
    }
    @discardableResult public func write(node: NamespaceNode, offset: Int64, data: Data, operationID: UUID? = nil, bufferedHandle: Bool = false) async throws -> NamespaceNode {
        await beginMutation(node.id)
        defer { finishMutation(node.id) }
        try Task.checkCancellation()
        let payloadChecksum = CoreFileIO.hash(data)
        let fingerprint = try mutationFingerprint(kind: "write", nodeID: node.id, offset: offset, payloadSHA256: payloadChecksum)
        if let replay = try await replayMutation(operationID, nodeID: node.id, fingerprint: fingerprint) { return replay }
        do { return try await writeValue(node: store.node(node.id), offset: offset, data: data, allowUnlinked: false, operationID: operationID, fingerprint: fingerprint, payloadChecksum: payloadChecksum, bufferedHandle: bufferedHandle) }
        catch NamespaceFailure.notFound {
            guard leases.values.contains(where: { $0.id == node.id }) else { throw NamespaceFailure.notFound }
            return try await writeValue(node: store.retainedNode(node.id), offset: offset, data: data, allowUnlinked: true, operationID: operationID, fingerprint: fingerprint, payloadChecksum: payloadChecksum)
        }
    }
    private func writeValue(node: NamespaceNode, offset: Int64, data: Data, allowUnlinked: Bool, operationID: UUID?, fingerprint: String, payloadChecksum: String, bufferedHandle: Bool = false) async throws -> NamespaceNode {
        guard node.kind == .file else { throw NamespaceFailure.isDirectory }
        guard offset >= 0 else { throw StorageFailure.invalidRange }
        if mode == .managed && !data.isEmpty {
            guard node.size <= Self.managedFileLimit, offset <= Self.managedFileLimit - Int64(data.count) else { throw StorageFailure.fileTooLarge }
        }
        if data.isEmpty {
            if let operationID { try await content.recordNoopResponse(id: operationID, fingerprint: fingerprint, node: node) }
            return node
        }
        guard node.contentGeneration < Int64.max else { throw StorageFailure.integrity }
        let bufferBytes = bufferedHandle && usesAdmissionFence && node.backing == nil && !allowUnlinked && data.count >= 256 * 1024 ? data.count : 0
        let snapshot: ContentSnapshot
        if mode == .managed {
            snapshot = try await content.prepareManagedWrite(nodeID: node.id, fromGeneration: node.contentGeneration,
                toGeneration: node.contentGeneration + 1, logicalSize: node.size, base: node.backing,
                previousSnapshotID: node.stagedSnapshotID, offset: offset, data: data, mutationFingerprint: fingerprint, prefix: prefix, remote: remote, payloadChecksum: payloadChecksum, orderedByNamespace: bufferBytes > 0)
        } else {
            snapshot = try await content.prepareWrite(nodeID: node.id, fromGeneration: node.contentGeneration,
                toGeneration: node.contentGeneration + 1, logicalSize: node.size, base: node.backing,
                previousSnapshotID: node.stagedSnapshotID, offset: offset, data: data, mutationFingerprint: fingerprint)
        }
        let operation = try await store.commitContent(nodeID: node.id, expectedGeneration: node.contentGeneration,
                                         newSize: snapshot.size, stagedSnapshotID: snapshot.id, operationID: operationID, allowUnlinked: allowUnlinked, mutationFingerprint: fingerprint, bufferBytes: bufferBytes)
        guard let accepted = operation.nodeSnapshot else { throw StorageFailure.integrity }
        if !allowUnlinked { noteManagedWrite(accepted.id); try? await noteNamespaceChange(nodeID: accepted.id) }
        return accepted
    }
    @discardableResult public func truncate(nodeID: NodeID, size: Int64, operationID: UUID? = nil) async throws -> NamespaceNode {
        await beginMutation(nodeID)
        defer { finishMutation(nodeID) }
        try Task.checkCancellation()
        let fingerprint = try mutationFingerprint(kind: "truncate", nodeID: nodeID, size: size)
        if let replay = try await replayMutation(operationID, nodeID: nodeID, fingerprint: fingerprint) { return replay }
        return try await truncateValue(node: store.node(nodeID), size: size, allowUnlinked: false, operationID: operationID, fingerprint: fingerprint)
    }
    @discardableResult public func truncate(node: NamespaceNode, size: Int64, operationID: UUID? = nil) async throws -> NamespaceNode {
        await beginMutation(node.id)
        defer { finishMutation(node.id) }
        try Task.checkCancellation()
        let fingerprint = try mutationFingerprint(kind: "truncate", nodeID: node.id, size: size)
        if let replay = try await replayMutation(operationID, nodeID: node.id, fingerprint: fingerprint) { return replay }
        do { return try await truncateValue(node: store.node(node.id), size: size, allowUnlinked: false, operationID: operationID, fingerprint: fingerprint) }
        catch NamespaceFailure.notFound {
            guard leases.values.contains(where: { $0.id == node.id }) else { throw NamespaceFailure.notFound }
            return try await truncateValue(node: store.retainedNode(node.id), size: size, allowUnlinked: true, operationID: operationID, fingerprint: fingerprint)
        }
    }
    private func truncateValue(node: NamespaceNode, size: Int64, allowUnlinked: Bool, operationID: UUID?, fingerprint: String) async throws -> NamespaceNode {
        guard node.kind == .file else { throw NamespaceFailure.isDirectory }
        guard node.contentGeneration < Int64.max else { throw StorageFailure.integrity }
        if mode == .managed, size > Self.managedFileLimit { throw StorageFailure.fileTooLarge }
        let snapshot = try await content.prepareTruncate(nodeID: node.id, fromGeneration: node.contentGeneration,
            toGeneration: node.contentGeneration + 1, logicalSize: node.size, base: node.backing,
            previousSnapshotID: node.stagedSnapshotID, size: size, mutationFingerprint: fingerprint)
        let operation = try await store.commitContent(nodeID: node.id, expectedGeneration: node.contentGeneration,
                                         newSize: size, stagedSnapshotID: snapshot.id, operationID: operationID, allowUnlinked: allowUnlinked, mutationFingerprint: fingerprint)
        guard let accepted = operation.nodeSnapshot else { throw StorageFailure.integrity }
        if !allowUnlinked { noteManagedWrite(accepted.id); try? await noteNamespaceChange(nodeID: accepted.id) }
        return accepted
    }
    @discardableResult public func submitSource(nodeID: NodeID, source: ResidentSourceIdentity, operationID: UUID? = nil) async throws -> NamespaceNode {
        await beginMutation(nodeID)
        defer { finishMutation(nodeID) }
        try Task.checkCancellation()
        let node = try await store.node(nodeID)
        guard node.kind == .file, node.contentGeneration < Int64.max else { throw StorageFailure.integrity }
        if mode == .managed, source.size > Self.managedFileLimit { throw StorageFailure.fileTooLarge }
        let snapshot = try await content.registerSource(nodeID: node.id, fromGeneration: node.contentGeneration, toGeneration: node.contentGeneration + 1, source: source)
        _ = try await store.commitContent(nodeID: node.id, expectedGeneration: node.contentGeneration, newSize: source.size,
                                         stagedSnapshotID: snapshot.id, operationID: operationID)
        let accepted = try await store.node(node.id); try? await noteNamespaceChange(nodeID: accepted.id); return accepted
    }
    @discardableResult public func createFromSource(parentID: NodeID, name: String, source: ResidentSourceIdentity, operationID: UUID? = nil) async throws -> NamespaceNode {
        let id = UUID()
        if mode == .managed, source.size > Self.managedFileLimit { throw StorageFailure.fileTooLarge }
        let snapshot = try await content.registerSource(nodeID: id, fromGeneration: 0, toGeneration: 1, source: source)
        let accepted = try await store.createContent(parentID: parentID, name: name, nodeID: id, snapshotID: snapshot.id,
                                              size: source.size, operationID: operationID)
        try? await noteNamespaceChange(nodeID: accepted.id); return accepted
    }
    public func status() async throws -> SyncEngineStatus {
        let volume = try await store.volume(), summary = try await store.pendingOperationSummary()
        let staging = await content.accounting(), cached = await cache.accounting(), pinRequests = try await cache.pinRequests()
        for request in pinRequests where request.state == "pending" || request.state == "working" || (request.state == "attention" && isRetryableManagedError(request.error)) { pendingPins.insert(request.nodeID) }
        startPinRunner()
        let pinAttention = pinRequests.filter { $0.state == "attention" }.count
        let waitingForNetwork = isRetryableManagedError(summary.firstError) || pinRequests.contains { $0.state == "pending" && isRetryableManagedError($0.error) }
        let phase: String
        if pauseRequested { phase = processing || preparingAhead ? "pausing" : "paused" }
        else if processing || preparingAhead { phase = "working" }
        else if summary.attentionErrors.contains(where: { !isRetryableManagedError($0) }) { phase = "attention" }
        else if waitingForNetwork { phase = "waitingForNetwork" }
        else if pinAttention > 0 || lastError != nil { phase = "attention" }
        else if summary.count > 0 { phase = "pending" }
        else { phase = pinRunner == nil ? "idle" : "working" }
        return .init(phase: phase,
                     pending: summary.count, attention: summary.attention,
                     localRevision: volume.revision, publishedRevision: volume.publishedRevision,
                     dirtyBytes: staging.dirtyBytes, cleanCacheBytes: cached.cleanBytes, pinnedBytes: cached.pinnedBytes,
                     lastError: lastError, activeOperationID: activeOperationID, retainedCleanBytes: staging.retainedCleanBytes, requestedPins: pinRequests.count,
                     completedPins: pinRequests.filter { $0.state == "complete" }.count, pinAttention: pinAttention,
                     pinRequestedBytes: pinRequests.reduce(0) { saturatingAdd($0, $1.size) }, pinCompletedBytes: pinRequests.reduce(0) { saturatingAdd($0, $1.completedBytes) },
                     uploadBytesPerSecond: uploadBytesPerSecond())
    }
    // Fits the upload transport's 9,999 parts of at most 64 MiB each,
    // including the framing overhead of an encrypted drive.
    public static let managedFileLimit: Int64 = 624 * 1024 * 1024 * 1024
    public func finderAvailableBytes(localAvailable: Int64, staging: ContentAccounting) -> Int64 {
        // R2 has no provider-reported volume quota. Reserve enough real space for
        // durable local index updates, then advertise the supported object range.
        if mode == .managed && localAvailable >= 16 * 1024 * 1024 { return Self.managedFileLimit }
        return max(0, min(localAvailable, staging.maximumBytes - staging.dirtyBytes - staging.retainedCleanBytes))
    }
    public func synchronize(waitForCloud: Bool = false) async throws {
        try await store.sealOpenWrites()
        guard waitForCloud else { return }
        guard !pauseRequested else { throw StorageFailure.busy }
        let target = try await store.volume().revision
        while try await store.operations(limit: 10_000).contains(where: { $0.sequence <= target }) {
            guard !pauseRequested else { throw StorageFailure.busy }
            try Task.checkCancellation()
            try await processPending()
        }
        guard try await store.volume().publishedRevision >= target else { throw StorageFailure.busy }
    }
    /// Explicit adoption of an imported tree. Metadata pages may be staged in the
    /// cloud incrementally; the public HEAD appears only after the entire fixed
    /// namespace revision has been inventoried and validated locally.
    public func publishInitialNamespace() async throws {
        guard mode == .managed, !processing else { throw StorageFailure.busy }
        processing = true; defer { processing = false }
        let volume = try await store.volume()
        guard try await store.operations(limit: 1).isEmpty else { throw StorageFailure.busy }
        if publisher == nil { publisher = ManagedManifestPublisher(remote: remote, prefix: prefix, volumeID: volume.id) }
        guard let publisher else { throw StorageFailure.integrity }
        let directory = content.directory.appendingPathComponent("managed-seed")
        try CoreFileIO.privateDirectory(directory)
        let checkpointURL = directory.appendingPathComponent("checkpoint.json"), intentURL = directory.appendingPathComponent("publication.json")
        if FileManager.default.fileExists(atPath: intentURL.path) {
            let publication = try CoreFileIO.readChecked(ManagedPublication.self, at: intentURL, maximum: 256 * 1024)
            guard publication.head.volumeID == volume.id, publication.commit.revision == volume.revision,
                  let operationID = publication.commit.operationIDs.first else { throw StorageFailure.conflict }
            try await publisher.publish(publication, operationID: operationID)
            try await store.recordNamespacePublication(revision: publication.commit.revision, validator: publication.head.commitID); return
        }
        var checkpoint: ManagedSeedCheckpoint
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            checkpoint = try CoreFileIO.readChecked(ManagedSeedCheckpoint.self, at: checkpointURL, maximum: 256 * 1024)
            guard checkpoint.volumeID == volume.id, checkpoint.rootID == volume.rootID, checkpoint.revision == volume.revision else { throw StorageFailure.conflict }
        } else { checkpoint = try await publisher.beginSeed(revision: volume.revision, rootID: volume.rootID, operationID: UUID()) }
        while true {
            guard try await store.volume().revision == volume.revision else { throw StorageFailure.busy }
            let page = try await store.allNodes(after: checkpoint.lastNodeID, limit: 4096)
            if page.nodes.isEmpty { break }
            checkpoint = try await publisher.appendSeed(checkpoint, records: page.nodes.map { ManagedNodeRecord(node: $0) })
            try CoreFileIO.atomicChecked(checkpoint, at: checkpointURL)
            if page.next == nil { break }
        }
        guard try await store.volume().revision == volume.revision else { throw StorageFailure.busy }
        let publication = try await publisher.finishSeed(checkpoint)
        try CoreFileIO.atomicChecked(publication, at: intentURL)
        guard try await store.volume().revision == volume.revision else { throw StorageFailure.busy }
        try await publisher.publish(publication, operationID: checkpoint.operationID)
        try await store.recordNamespacePublication(revision: publication.commit.revision, validator: publication.head.commitID)
    }
    public func requestPause() { pauseRequested = true }
    public func resume() async throws {
        pauseRequested = false
        retryAfter = nil
        pinRetryAfter = nil
        for request in try await cache.pinRequests() where request.state == "attention" {
            if let node = try? await store.node(request.nodeID) {
                try await cache.requestPin(node: node, recursive: request.recursive); pendingPins.insert(node.id)
            }
        }
        startPinRunner()
        for operation in try await store.operations(limit: 10_000) where operation.state == .attention {
            try await store.setOperationState(operation.id, state: .pending)
        }
        try await processPending()
    }
    public func processPending(limit: Int = 64, waitForQuiet: Bool = false) async throws {
        guard !processing else { throw StorageFailure.busy }
        guard !pauseRequested else { return }
        guard (1...256).contains(limit) else { throw StorageFailure.invalidRange }
        startPinRunner()
        if waitForQuiet, let retryAfter, ContinuousClock.now < retryAfter { return }
        retryAfter = nil
        processing = true; defer { processing = false; activeOperationID = nil }
        let operations = try await EngineTrace.measure("processPending.operations") { try await store.operations(limit: limit) }
        try await EngineTrace.measure("processPending.seal") { try await store.sealOpenWrites() } // Every candidate can now be published.
        let now = ContinuousClock.now
        lastManagedWrite = lastManagedWrite.filter { $0.value.advanced(by: .seconds(2)) > now }
        // Immutable managed payloads may be prepared out of order, but namespace
        // publication and the durable dependency frontier remain strictly ordered.
        // Keep the look-ahead bounded; compatible path mutations never use this lane.
        var preparationFailures: [UUID: Error] = [:]
        var preparedOperations: Set<UUID> = []
        var completedThrough: Int64 = -1
        var completionsSinceReclaim = 0
        for (index, operation) in operations.enumerated() {
            guard !pauseRequested else { break }
            if operation.sequence <= completedThrough { continue }
            try Task.checkCancellation()
            if operation.state == .attention {
                guard isRetryableManagedError(operation.errorCode) else { throw StorageFailure.conflict }
                try await store.setOperationState(operation.id, state: .pending)
            }
            for dependency in operation.dependencies {
                guard try await store.operation(dependency)?.state == .complete else { throw StorageFailure.busy }
            }
            // Finder still has a writer feeding this file. Give its newest durable
            // snapshot a short settling period before uploading the whole snapshot.
            // Explicit cloud sync/eject bypasses this background-only delay.
            if waitForQuiet, operation.kind == .write, lastManagedWrite[operation.nodeID] != nil { break }
            if mode == .managed {
                let eligible = Array(operations[index...].prefix { candidate in
                    !waitForQuiet || candidate.kind != .write || lastManagedWrite[candidate.nodeID] == nil
                })
                let batch = try await EngineTrace.measure("managedPublicationBatch") { try await store.managedPublicationBatch(first: operation, candidates: eligible) }
                if let last = batch.last {
                    activeOperationID = operation.id
                    do {
                        try await store.setOperationState(operation.id, state: .running)
                        try await EngineTrace.measure("processManagedPublicationBatch(\(batch.count))") { try await processManagedPublicationBatch(batch) }
                        try await EngineTrace.measure("completeManagedPublicationBatch") { try await store.completeManagedPublicationBatch(batch) }
                    } catch Control.pauseRequested {
                        try await store.setOperationState(operation.id, state: .pending)
                        break
                    } catch {
                        try await recordFailure(error, operation: operation)
                        throw error
                    }
                    completedThrough = last.sequence
                    lastError = nil
                    completionsSinceReclaim += batch.count
                    if !waitForQuiet, completionsSinceReclaim >= 32 {
                        do { try await reclaimPublishedLocalData() }
                        catch { lastError = "localReclamationDeferred" }
                        completionsSinceReclaim = 0
                    }
                    await EngineTrace.measure("noteNamespaceChange(\(batch.count))") { for id in Set(batch.map(\.nodeID)) { try? await noteNamespaceChange(nodeID: id) } }
                    continue
                }
            }
            if mode == .managed, operation.kind == .write, !preparedOperations.contains(operation.id) {
                // Fold each consecutive write run before selecting its immutable
                // payload. The old three-operation window excluded repeated writes
                // and was bypassed entirely by Finder's folded write runs.
                var candidates: [NamespaceOperation] = []
                var selectedNodes: Set<NodeID> = []
                var through: Int64 = -1
                for (offset, candidate) in operations[index...].enumerated() {
                    if candidate.state == .attention { break }
                    if candidate.sequence <= through { continue }
                    guard candidate.kind == .write,
                          !preparedOperations.contains(candidate.id),
                          !selectedNodes.contains(candidate.nodeID),
                          !waitForQuiet || lastManagedWrite[candidate.nodeID] == nil else { continue }
                    let position = index + offset
                    let nextMatches = position + 1 < operations.count && operations[position + 1].kind == .write && operations[position + 1].nodeID == candidate.nodeID
                    let run = try await store.managedWriteRun(first: candidate, allowNew: nextMatches)
                    let payload = run.last ?? candidate
                    through = payload.sequence
                    selectedNodes.insert(candidate.nodeID)
                    preparedOperations.insert(candidate.id)
                    preparedOperations.insert(payload.id)
                    candidates.append(payload)
                    if candidates.count == managedUploadConcurrency { break }
                }
                preparationFailures.merge(await prepareManagedBatch(candidates)) { _, new in new }
                guard !pauseRequested else { break }
            }
            if mode == .managed && operation.kind == .write {
                let nextMatches = index + 1 < operations.count && operations[index + 1].kind == .write && operations[index + 1].nodeID == operation.nodeID
                let group = try await store.managedWriteRun(first: operation, allowNew: nextMatches)
                if let last = group.last {
                    try await store.sealOpenWrites() // The group may include writes admitted after the initial look-ahead.
                    activeOperationID = operation.id
                    do {
                        try await store.setOperationState(operation.id, state: .running)
                        if let error = preparationFailures[last.id] { throw error }
                        try await processManaged(last)
                        try await store.completeManagedWriteRun(group)
                    } catch Control.pauseRequested {
                        try await store.setOperationState(operation.id, state: .pending)
                        break
                    } catch {
                        try await recordFailure(error, operation: operation)
                        throw error
                    }
                    completedThrough = last.sequence
                    try? await noteNamespaceChange(nodeID: last.nodeID)
                    lastError = nil
                    continue
                }
            }
            activeOperationID = operation.id
            do {
                try await store.setOperationState(operation.id, state: .running)
                if let id = operation.stagedSnapshotID, let fingerprint = try await content.snapshot(id: id).mutationFingerprint {
                    try await store.recordReceipt(operationID: operation.id, stepID: "mutation-fingerprint", validator: fingerprint)
                }
                if let error = preparationFailures[operation.id] { throw error }
                if mode == .managed { try await processManaged(operation) }
                else { try await processCompatible(operation) }
                try await receipt(operation, step: "finished", value: operation.sequence)
                try await store.completeOperation(operation.id)
                // Inventory decodes the pending journal. Amortize it rather than
                // rescanning thousands of records for every metadata operation.
                // Completion remains durable; delayed reclamation only retains data.
                completionsSinceReclaim += 1
                if !waitForQuiet, completionsSinceReclaim >= 32 {
                    do { try await reclaimPublishedLocalData(); lastError = nil }
                    catch { lastError = "localReclamationDeferred" }
                    completionsSinceReclaim = 0
                }
                if operation.kind != .remove { try? await noteNamespaceChange(nodeID: operation.nodeID) }
            } catch Control.pauseRequested {
                try await store.setOperationState(operation.id, state: .pending)
                break
            } catch {
                try await recordFailure(error, operation: operation)
                throw error
            }
        }
        // Background passes run every two seconds, even if the oldest
        // operation is waiting for Finder to finish a write. Coalesce sweeps
        // so large journals do not repeatedly block publication or admission.
        if waitForQuiet, let backgroundReclaimAfter, ContinuousClock.now < backgroundReclaimAfter { return }
        // Inventory walks every content row and every pending write while holding
        // the namespace store, which stalls uploads and status on a deep backlog.
        // It only frees local cache, so spend at most about 5% of the time on it.
        let reclaimStart = ContinuousClock.now
        defer {
            let took = ContinuousClock.now - reclaimStart
            EngineTrace.record("reclaimPublishedLocalData(background)", took)
            backgroundReclaimAfter = .now.advanced(by: max(.seconds(15), took * 20))
        }
        do { try await reclaimPublishedLocalData(); lastError = nil }
        catch { lastError = "localReclamationDeferred" }
    }
    /// Persist intent and return promptly. The bounded background reader reports
    /// partial/failed progress; requesting a pin never claims all bytes are resident.
    public func pin(nodeID: NodeID, recursive: Bool = false) async throws {
        let node = try await store.node(nodeID)
        try await cache.requestPin(node: node, recursive: recursive && node.kind == .directory)
        pendingPins.insert(nodeID); startPinRunner()
    }
    public func unpin(nodeID: NodeID, recursive: Bool = false) async throws {
        for node in try await subtree(nodeID, recursive: recursive) { try await cache.unpin(nodeID: node.id); pendingPins.remove(node.id) }
    }
    public func noteNamespaceChange(nodeID: NodeID) async throws {
        guard await cache.changeMayAffectPin(nodeID: nodeID) else { return }
        let node = try await store.node(nodeID)
        var desired = await cache.isPinned(nodeID: nodeID), cursor = node.parentID, visited = Set<UUID>()
        while !desired, let parent = cursor {
            guard visited.insert(parent).inserted, visited.count <= 4096 else { throw StorageFailure.integrity }
            desired = await cache.isRecursivelyPinned(nodeID: parent)
            let ancestor = try await store.node(parent)
            if desired {
                try await cache.requestPin(node: ancestor, recursive: true); pendingPins.insert(parent)
            }
            cursor = ancestor.parentID
        }
        if desired {
            let recursive = await cache.isRecursivelyPinned(nodeID: nodeID)
            try await cache.requestPin(node: node, recursive: recursive)
            pendingPins.insert(nodeID); startPinRunner()
        }
    }
    private func startPinRunner() {
        guard !pauseRequested, pinRunner == nil, !pendingPins.isEmpty else { return }
        if let pinRetryAfter, ContinuousClock.now < pinRetryAfter { return }
        pinRunner = Task { [weak self] in await self?.runPins() }
    }
    private func runPins() async {
        defer { pinRunner = nil }
        while !pauseRequested, let id = pendingPins.popFirst() {
            do {
                guard let initial = try await cache.pinRequest(nodeID: id) else { continue }
                let root = try await store.node(id)
                try await cache.requestPin(node: root, recursive: initial.recursive)
                guard let request = try await cache.pinRequest(nodeID: id) else { continue }
                let nodes = try await subtree(id, recursive: request.recursive)
                var failed = false
                for node in nodes {
                    if pauseRequested { pendingPins.insert(id); try? await cache.updatePin(nodeID: id, completedBytes: 0, state: "pending"); return }
                    if request.recursive { guard await cache.isRecursivelyPinned(nodeID: id) else { break } }
                    else { guard await cache.isPinned(nodeID: id) else { break } }
                    if node.id != id { try await cache.requestPin(node: node, recursive: false) }
                    do {
                        var completed: Int64 = 0
                        try await cache.updatePin(nodeID: node.id, completedBytes: 0, state: "working")
                        if node.kind == .file {
                            while completed < node.size {
                                if pauseRequested { throw Control.pauseRequested }
                                guard await cache.isPinned(nodeID: node.id) else { break }
                                let bytes = try await readValue(node: node, offset: completed, length: cache.chunkSize, requireResident: true)
                                guard !bytes.isEmpty else { throw StorageFailure.integrity }
                                completed += Int64(bytes.count)
                                try await cache.updatePin(nodeID: node.id, completedBytes: completed, state: "working")
                            }
                        }
                        guard await cache.isPinned(nodeID: node.id) else { continue }
                        let current = try await store.node(node.id)
                        let generation = node.kind == .file ? node.contentGeneration : node.metadataGeneration
                        let now = current.kind == .file ? current.contentGeneration : current.metadataGeneration
                        if generation != now { try await cache.requestPin(node: current, recursive: node.id == id && request.recursive); pendingPins.insert(node.id) }
                        else { try await cache.updatePin(nodeID: node.id, completedBytes: completed, state: "complete") }
                    } catch Control.pauseRequested {
                        let progress = try? await cache.pinRequest(nodeID: node.id)
                        try? await cache.updatePin(nodeID: node.id, completedBytes: progress?.completedBytes ?? 0, state: "pending")
                        if request.recursive { try? await cache.updatePin(nodeID: id, completedBytes: 0, state: "pending") }
                        pendingPins.insert(id); return
                    } catch {
                        let progress = try? await cache.pinRequest(nodeID: node.id)
                        let code = classify(error)
                        if isRetryableManagedError(code) {
                            try await cache.updatePin(nodeID: node.id, completedBytes: progress?.completedBytes ?? 0, state: "pending", error: code)
                            if request.recursive && node.id != id {
                                try await cache.updatePin(nodeID: id, completedBytes: 0, state: "pending", error: code)
                            }
                            pinRetryAfter = .now.advanced(by: .seconds(4))
                            pendingPins.insert(id)
                            return
                        }
                        failed = true
                        try? await cache.updatePin(nodeID: node.id, completedBytes: progress?.completedBytes ?? 0, state: "attention", error: classify(error))
                    }
                }
                if request.recursive, await cache.isPinned(nodeID: id),
                   let currentRequest = try await cache.pinRequest(nodeID: id), currentRequest.generation == request.generation {
                    try await cache.updatePin(nodeID: id, completedBytes: 0, state: failed ? "attention" : "complete", error: failed ? "pinIncomplete" : nil)
                }
            } catch { try? await cache.updatePin(nodeID: id, completedBytes: 0, state: "attention", error: classify(error)) }
        }
    }
    public func pinProgress() async throws -> [PinProgress] { try await cache.pinRequests() }
    public func freeLocalSpace(nodeID: NodeID, recursive: Bool = false) async throws { for node in try await subtree(nodeID, recursive: recursive) { try await cache.free(nodeID: node.id) } }

    public func reclaimPublishedLocalData(includingRemote: Bool = true) async throws {
        let inventory = try await store.snapshotInventory()
        var open = Set(leases.values.compactMap(\.stagedSnapshotID))
        open.formUnion(pendingPayloads.values.compactMap(\.snapshotID))
        // A handle can write newer generations after unlink. Its original captured
        // snapshot alone does not protect those subsequently accepted bytes.
        for node in leases.values { open.formUnion(inventory.unpublishedByNode[node.id] ?? []) }
        try await content.reclaim(published: inventory.published, retaining: inventory.pending.union(open), discarded: inventory.discarded)
        if mode == .managed && includingRemote { try await content.reclaimCloudExtents(prefix: prefix, remote: remote) }
    }
    private func processCompatible(_ operation: NamespaceOperation) async throws {
        let node = try await store.retainedNode(operation.nodeID)
        switch operation.kind {
        case .create:
            if node.kind == .directory {
                let key = try remoteKey(operation.destinationPath) + "/"
                let object = try await putReconciled(key: key, data: Data(), condition: .absent, operation: operation)
                try await receipt(operation, step: "uploaded", value: object)
            } else if operation.stagedSnapshotID == nil {
                let object = try await putReconciled(key: remoteKey(operation.destinationPath), data: Data(), condition: .absent, operation: operation)
                try await receipt(operation, step: "uploaded", value: object)
                try await markPublishedIfCurrent(nodeID: node.id, generation: 0, object: object)
            }
        case .write:
            guard let id = operation.stagedSnapshotID else { throw StorageFailure.integrity }
            let snapshot = try await content.snapshot(id: id)
            guard snapshot.generation == operation.targetGeneration, snapshot.nodeID == operation.nodeID else { throw StorageFailure.integrity }
            let key = try remoteKey(operation.destinationPath)
            let object: StorageObject
            if let previous: StorageObject = try await savedReceipt(operation, step: "uploaded") {
                guard let actual = try await remote.head(key: key), same(actual, previous) else { throw StorageFailure.conflict }
                object = previous
            } else {
                let expected = try await expectedObject(operation: operation, key: key)
                if let expected { try await preserveBeforeOverwrite(expected, operation: operation) }
                let condition = expected.map { StorageCondition.matches($0.validator) } ?? .absent
                do { object = try await remote.upload(key: key, size: snapshot.size, condition: condition, operationID: operation.id, reader: { [self] range in try await self.readUploadRange(snapshot: snapshot, range: range) }) }
                catch {
                    guard let actual = try await remote.head(key: key), actual.operationID == operation.id, actual.size == snapshot.size else { throw error }
                    try await receipt(operation, step: "uploaded", value: actual)
                    try await markPublishedIfCurrent(nodeID: node.id, generation: snapshot.generation, object: actual)
                    return
                }
                guard object.size == snapshot.size else { throw StorageFailure.invalidResponse }
                try await receipt(operation, step: "uploaded", value: object)
            }
            try await markPublishedIfCurrent(nodeID: node.id, generation: snapshot.generation, object: object)
        case .rename:
            try await relocate(operation, directory: node.kind == .directory)
        case .remove:
            if node.kind == .directory {
                let entries = try await historicalSubtree(operation)
                if entries.count > 1 {
                    try await relocate(operation, directory: true, destinationOverride: prefix + "/.clouddrive/compatible/v1/tombstones/" + operation.id.uuidString)
                    return
                }
            }
            let key = try remoteKey(operation.sourcePath) + (node.kind == .directory ? "/" : "")
            guard let actual = try await expectedObject(operation: operation, key: key) else {
                if try await remote.head(key: key) != nil { throw StorageFailure.conflict }
                return
            }
            if node.kind == .file { try await preserveBeforeOverwrite(actual, operation: operation) }
            try await remote.delete(key: key, validator: actual.validator)
        case .pin: break
        case .metadata:
            guard let date = operation.modifiedAt else { throw StorageFailure.integrity }
            let key = try remoteKey(operation.destinationPath ?? operation.sourcePath) + (node.kind == .directory ? "/" : "")
            let previous: StorageObject
            if let known = try await expectedObject(operation: operation, key: key) { previous = known }
            else if node.kind == .directory {
                if let actual = try await remote.head(key: key) { guard actual.size == 0 else { throw StorageFailure.conflict }; previous = actual }
                else { previous = try await putReconciled(key: key, data: Data(), condition: .absent, operation: operation); try await receipt(operation, step: "uploaded", value: previous) }
            } else { throw StorageFailure.conflict }
            let modified: StorageObject
            if let saved: StorageObject = try await savedReceipt(operation, step: "modified") { guard let actual = try await remote.head(key: key), same(saved, actual) else { throw StorageFailure.conflict }; modified = saved }
            else {
                if let actual = try await remote.head(key: key), actual.operationID == operation.id,
                   let observed = actual.modifiedAt, abs(observed.timeIntervalSince(date)) <= 0.001,
                   actual.size == previous.size, previous.checksum == nil || actual.checksum == previous.checksum { modified = actual }
                else { modified = try await remote.setModifiedAt(key: key, validator: previous.validator, date: date, operationID: operation.id) }
                guard modified.key == key, modified.size == previous.size, previous.checksum == nil || modified.checksum == previous.checksum else { throw StorageFailure.integrity }
                try await receipt(operation, step: "modified", value: modified)
            }
            try await content.recordVerifiedRelocation(source: locator(previous), destination: locator(modified))
            if node.kind == .file { try await store.markContentRelocated(nodeID: node.id, generation: operation.nodeSnapshot?.contentGeneration ?? node.contentGeneration, expectedBacking: locator(previous), backing: locator(modified)) }

        }
    }
    private func preserveBeforeOverwrite(_ object: StorageObject, operation: NamespaceOperation) async throws {
        let step = "preserved-" + CoreFileIO.hash(Data((object.key + object.validator).utf8))
        let backup: StorageObject
        if let existing: StorageObject = try await savedReceipt(operation, step: step) {
            guard let actual = try await remote.head(key: existing.key), same(actual, existing) else { throw StorageFailure.conflict }; backup = existing
        } else {
            let target = prefix + "/.clouddrive/compatible/v1/retained/" + CoreFileIO.hash(Data((object.key + ":" + object.validator).utf8))
            if let existing = try await remote.head(key: target) {
                guard existing.size == object.size, existing.operationID == operation.id || (object.checksum != nil && existing.checksum == object.checksum) else { throw StorageFailure.conflict }
                backup = existing
            } else { backup = try await remote.copy(source: object.key, destination: target, sourceValidator: object.validator, operationID: operation.id) }
            guard backup.size == object.size, object.checksum == nil || backup.checksum == object.checksum else { throw StorageFailure.integrity }
            try await receipt(operation, step: step, value: backup)
        }
        try await content.recordVerifiedRelocation(source: locator(object), destination: locator(backup))
    }
    private func relocate(_ operation: NamespaceOperation, directory: Bool, destinationOverride: String? = nil) async throws {
        let source = try remoteKey(operation.sourcePath)
        let destination = try destinationOverride ?? remoteKey(operation.destinationPath)
        guard source != destination, !destination.hasPrefix(source + "/") else { throw StorageFailure.conflict }
        let journalDirectory = content.directory.appendingPathComponent("relocations/" + operation.id.uuidString)
        try CoreFileIO.privateDirectory(journalDirectory)
        let manifestURL = journalDirectory.appendingPathComponent("manifest.json")
        var manifest: RelocationManifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try CoreFileIO.readChecked(RelocationManifest.self, at: manifestURL, maximum: 2 * 1024 * 1024)
            guard manifest.version == 1, manifest.operationID == operation.id, manifest.source == source, manifest.destination == destination else { throw StorageFailure.integrity }
        } else { manifest = .init(operationID: operation.id, source: source, destination: destination) }
        if !manifest.inventoryComplete {
            if directory {
                let historical = try await historicalSubtree(operation)
                var expected = [String: ObjectLocator](), directories = Set<String>()
                for (node, relative) in historical {
                    let key = source + (relative.isEmpty ? "" : "/" + relative)
                    if node.kind == .directory { directories.insert(key + "/"); continue }
                    let backing = try await store.publishedLocator(nodeID: node.id, generation: node.contentGeneration) ?? node.backing
                    guard let backing else { throw StorageFailure.conflict }
                    if backing.key == key { expected[key] = backing }
                    else { let resolved = try await content.resolve(backing); guard resolved.key == key else { throw StorageFailure.conflict }; expected[key] = resolved }
                }
                if manifest.listingFinished != true {
                repeat {
                    let page = try await remote.list(prefix: source + "/", cursor: manifest.cursor, limit: 128)
                    guard page.objects.count <= 128, page.nextCursor != manifest.cursor || page.nextCursor == nil else { throw StorageFailure.invalidResponse }
                    let values = try page.objects.map { object -> RelocationObject in
                        guard object.key.hasPrefix(source + "/"), object.size >= 0 else { throw StorageFailure.invalidResponse }
                        if let proof = expected[object.key] {
                            guard object.size == proof.size, object.validator == proof.validator,
                                  proof.checksum == nil || object.checksum == proof.checksum else { throw StorageFailure.conflict }
                        } else { guard object.size == 0, directories.contains(object.key) else { throw StorageFailure.conflict } }
                        return .init(source: object, destination: destination + object.key.dropFirst(source.count))
                    }
                    let id = UUID(); try CoreFileIO.atomicChecked(values, at: journalDirectory.appendingPathComponent(id.uuidString + ".json"))
                    manifest.pages.append(id); manifest.cursor = page.nextCursor; manifest.listingFinished = page.nextCursor == nil
                    guard manifest.pages.count <= 8192 else { throw StorageFailure.localStorageFull }
                    try CoreFileIO.atomicChecked(manifest, at: manifestURL)
                    try pauseBoundary()
                } while manifest.listingFinished != true
                }
                var seen = Set<String>()
                for pageID in manifest.pages { for value in try readPage(pageID, in: journalDirectory) { guard seen.insert(value.source.key).inserted else { throw StorageFailure.invalidResponse } } }
                guard Set(expected.keys).isSubset(of: seen) else { throw StorageFailure.conflict }
                manifest.inventoryComplete = true
                try CoreFileIO.atomicChecked(manifest, at: manifestURL)
            } else {
                let expected = try await expectedObject(operation: operation, key: source)
                guard let object = expected, let actual = try await remote.head(key: source), same(object, actual) else { throw StorageFailure.conflict }
                let id = UUID(); try CoreFileIO.atomicChecked([RelocationObject(source: actual, destination: destination)], at: journalDirectory.appendingPathComponent(id.uuidString + ".json"))
                manifest.pages = [id]; manifest.inventoryComplete = true
                try CoreFileIO.atomicChecked(manifest, at: manifestURL)
            }
        }
        // Copy/receipt all pages before admitting any source deletion.
        for pageID in manifest.pages {
            for item in try readPage(pageID, in: journalDirectory) {
                try pauseBoundary()
                let step = "copy-" + CoreFileIO.hash(Data(item.source.key.utf8))
                if let saved: StorageObject = try await savedReceipt(operation, step: step) {
                    guard saved.key == item.destination, let actual = try await remote.head(key: saved.key), same(saved, actual) else { throw StorageFailure.conflict }
                    continue
                }
                guard let sourceNow = try await remote.head(key: item.source.key), same(sourceNow, item.source) else { throw StorageFailure.conflict }
                let copied: StorageObject
                if let existing = try await remote.head(key: item.destination) {
                    if existing.operationID == operation.id {
                        guard existing.size == item.source.size else { throw StorageFailure.conflict }; copied = existing
                    } else {
                        try await prepareReplacement(existing, operation: operation)
                        copied = try await remote.copy(source: item.source.key, destination: item.destination, sourceValidator: item.source.validator, operationID: operation.id)
                    }
                } else { copied = try await remote.copy(source: item.source.key, destination: item.destination, sourceValidator: item.source.validator, operationID: operation.id) }
                guard copied.size == item.source.size, copied.key == item.destination,
                      item.source.checksum == nil || item.source.checksum == copied.checksum else { throw StorageFailure.integrity }
                try await receipt(operation, step: step, value: copied)
            }
        }
        for pageID in manifest.pages {
            var aliases = [(ObjectLocator, ObjectLocator)]()
            for item in try readPage(pageID, in: journalDirectory) {
                try pauseBoundary()
                guard let copied: StorageObject = try await savedReceipt(operation, step: "copy-" + CoreFileIO.hash(Data(item.source.key.utf8))),
                      copied.key == item.destination, let destinationNow = try await remote.head(key: copied.key), same(copied, destinationNow) else { throw StorageFailure.conflict }
                let deleted: StorageObject? = try await savedReceipt(operation, step: "deleted-" + CoreFileIO.hash(Data(item.source.key.utf8)))
                if deleted == nil {
                    if let sourceNow = try await remote.head(key: item.source.key) { guard same(sourceNow, item.source) else { throw StorageFailure.conflict } }
                    else { let intent: StorageObject? = try await savedReceipt(operation, step: "delete-intent-" + CoreFileIO.hash(Data(item.source.key.utf8))); guard intent != nil else { throw StorageFailure.conflict } }
                }
                aliases.append((locator(item.source), locator(copied)))
            }
            try await content.recordVerifiedRelocations(aliases)
        }
        try await receipt(operation, step: "copy-barrier", value: operation.id)
        // Retained generations and staged base reads now use durable verified aliases.
        for pageID in manifest.pages {
            for item in try readPage(pageID, in: journalDirectory) {
                try pauseBoundary()
                let step = "deleted-" + CoreFileIO.hash(Data(item.source.key.utf8))
                if let _: StorageObject = try await savedReceipt(operation, step: step) { continue }
                if let sourceNow = try await remote.head(key: item.source.key) {
                    guard same(sourceNow, item.source), let copied: StorageObject = try await savedReceipt(operation, step: "copy-" + CoreFileIO.hash(Data(item.source.key.utf8))),
                          copied.key == item.destination, let destinationNow = try await remote.head(key: copied.key), same(copied, destinationNow) else { throw StorageFailure.conflict }
                    try await receipt(operation, step: "delete-intent-" + CoreFileIO.hash(Data(item.source.key.utf8)), value: item.source)
                    try await remote.delete(key: item.source.key, validator: item.source.validator)
                }
                // If DELETE's response was lost, only this journaled source version
                // may be reconciled as absent; the durable verified copy is retained.
                try await receipt(operation, step: step, value: item.source)
            }
        }
        // Rebase historical generation locators without clearing any newer local write.
        for (node, _) in try await historicalSubtree(operation) where node.kind == .file {
            if let backing = try await store.publishedLocator(nodeID: node.id, generation: node.contentGeneration) ?? node.backing {
                let resolved = try await content.resolve(backing)
                if resolved != backing { try await store.markContentRelocated(nodeID: node.id, generation: node.contentGeneration, expectedBacking: backing, backing: resolved) }
            }
        }
    }
    private func prepareReplacement(_ object: StorageObject, operation: NamespaceOperation) async throws {
        guard let id = operation.replacedNodeID else { throw StorageFailure.conflict }
        let previous = try await store.nodeAsOf(id, revision: max(0, operation.sequence - 1))
        let key = try remoteKey(operation.destinationPath) + (previous.kind == .directory ? "/" : "")
        guard object.key == key else { throw StorageFailure.conflict }
        if previous.kind == .file {
            let proof = try await store.publishedLocator(nodeID: id, generation: previous.contentGeneration) ?? previous.backing
            guard let proof, proof.size == object.size, proof.validator == object.validator else { throw StorageFailure.conflict }
        } else {
            guard object.size == 0 else { throw StorageFailure.conflict }
            let children = try await remote.list(prefix: key, cursor: nil, limit: 2)
            guard children.objects.allSatisfy({ $0.key == key }) else { throw StorageFailure.conflict }
        }
        try await preserveBeforeOverwrite(object, operation: operation)
        try await receipt(operation, step: "replace-intent", value: object)
        try await remote.delete(key: object.key, validator: object.validator)
        try await receipt(operation, step: "replace-removed", value: object)
    }
    private func historicalSubtree(_ operation: NamespaceOperation) async throws -> [(NamespaceNode, String)] {
        let revision = operation.kind == .remove ? max(0, operation.sequence - 1) : operation.sequence
        let root = try await store.nodeAsOf(operation.nodeID, revision: revision)
        var result = [(root, "")], queue = [(root.id, "")], index = 0
        while index < queue.count {
            let (parent, relative) = queue[index]; index += 1
            guard try await store.nodeAsOf(parent, revision: revision).kind == .directory else { continue }
            var cursor: String?
            repeat {
                let page = try await store.listAsOf(parentID: parent, revision: revision, after: cursor, limit: 256)
                for node in page.nodes {
                    let path = relative.isEmpty ? node.name : relative + "/" + node.name
                    result.append((node, path)); if node.kind == .directory { queue.append((node.id, path)) }
                }
                guard result.count <= 1_000_000 else { throw StorageFailure.localStorageFull }
                cursor = page.next
            } while cursor != nil
        }
        return result
    }
    /// A prepared object is not publication: it cannot clear dirty bytes, advance
    /// revisions, or permit source reclamation. Receipts make restart/lost replies
    /// reconcile at the same immutable operation key.
    private func prepareManagedContent(_ operation: NamespaceOperation, node: NamespaceNode) async throws -> StorageObject {
        if pendingPayloads[operation.id] != nil {
            return try await withCheckedThrowingContinuation { continuation in
                pendingPayloads[operation.id]?.waiters.append(continuation)
            }
        }
        pendingPayloads[operation.id] = PendingPayload(snapshotID: operation.stagedSnapshotID)
        let result: Result<StorageObject, Error>
        do { result = .success(try await uploadManagedPayload(operation, node: node)) }
        catch { result = .failure(error) }
        let waiters = pendingPayloads.removeValue(forKey: operation.id)?.waiters ?? []
        for waiter in waiters { waiter.resume(with: result) }
        return try result.get()
    }

    private func uploadManagedPayload(_ operation: NamespaceOperation, node: NamespaceNode) async throws -> StorageObject {
        let generation = operation.kind == .write ? operation.targetGeneration : 0
        let key = prefix + "/.clouddrive/v1/content/" + node.id.uuidString + "/" + String(generation) + "/" + operation.id.uuidString
        let object: StorageObject
        if let saved: StorageObject = try await savedReceipt(operation, step: "uploaded") {
            guard let actual = try await remote.head(key: saved.key), same(saved, actual) else { throw StorageFailure.conflict }; object = saved
        } else if let id = operation.stagedSnapshotID {
            let snapshot = try await content.snapshot(id: id)
            guard snapshot.nodeID == node.id, snapshot.generation == generation, snapshot.size == node.size else { throw StorageFailure.integrity }
            do {
                object = try await remote.uploadContent(keyHint: key, size: snapshot.size, operationID: operation.id,
                    reader: { [self] range in
                        try await self.readUploadRange(snapshot: snapshot, range: range)
                    })
            }
            catch { guard let actual = try await remote.head(key: key), actual.operationID == operation.id, actual.size == snapshot.size else { throw error }; object = actual }
            guard object.key.hasPrefix(prefix + "/.clouddrive/v1/content/"), object.size == snapshot.size else { throw StorageFailure.invalidResponse }
            try await receipt(operation, step: "uploaded", value: object)
        } else { object = try await putReconciled(key: key, data: Data(), condition: .absent, operation: operation); try await receipt(operation, step: "uploaded", value: object) }
        return object
    }

    /// Prepare sealed payloads independently of the namespace publisher. The
    /// existing uploaded receipt is the only durable side effect in this lane.
    public func prepareManagedPayloadsAhead() async {
        guard mode == .managed, !pauseRequested, !preparingAhead,
              retryAfter.map({ .now >= $0 }) != false else { return }
        preparingAhead = true
        defer { preparingAhead = false }
        while !Task.isCancelled, !pauseRequested, retryAfter.map({ .now >= $0 }) != false {
            guard let operations = try? await EngineTrace.measure("managedPayloadCandidates") { try await store.managedPayloadCandidates(limit: 16) },
                  !operations.isEmpty, !pauseRequested else { return }
            let results = await ManagedUploadPipeline.run(sizes: operations.map { $0.nodeSnapshot?.size ?? 0 },
                maximumFiles: min(4, managedUploadConcurrency),
                shouldContinue: { [self] in
                    guard !Task.isCancelled else { return false }
                    return await self.canPrepareManagedPayload()
                },
                prepare: { [self] index in try await self.prepareAhead(operations[index]) })
            // Refill after a productive window. Yield to the owner's regular
            // poll when open files, a failure, or a pause prevent progress.
            var uploaded = false
            for result in results.values {
                guard case .success(let prepared) = result else { return }
                uploaded = uploaded || prepared
            }
            guard uploaded else { return }
        }
    }

    private func prepareAhead(_ operation: NamespaceOperation) async throws -> Bool {
        guard let node = try? await store.node(operation.nodeID),
              node.contentGeneration == operation.targetGeneration, node.stagedSnapshotID == operation.stagedSnapshotID,
              !pauseRequested, lastManagedWrite[node.id].map({ $0.advanced(by: .seconds(2)) <= .now }) != false,
              !leases.values.contains(where: { $0.id == node.id }) else { return false }
        try Task.checkCancellation()
        _ = try await prepareManagedContent(operation, node: node)
        return true
    }
    private func prepareManagedBatch(_ operations: [NamespaceOperation]) async -> [UUID: Error] {
        await withTaskGroup(of: (UUID, Result<Void, Error>).self) { group in
            for operation in operations {
                // Do not speculatively cross an existing attention barrier.
                if operation.state == .attention { break }
                guard !pauseRequested, operation.kind == .write,
                      operation.stagedSnapshotID != nil, let node = operation.nodeSnapshot else { continue }
                group.addTask { [self] in
                    do {
                        try Task.checkCancellation()
                        _ = try await prepareManagedContent(operation, node: node)
                        return (operation.id, .success(()))
                    } catch { return (operation.id, .failure(error)) }
                }
            }
            var failures: [UUID: Error] = [:]
            for await (id, result) in group {
                if case .failure(let error) = result { failures[id] = error }
            }
            return failures
        }
    }
    private func processManagedPublicationBatch(_ batch: [NamespaceOperation]) async throws {
        guard let first = batch.first, let last = batch.last else { throw StorageFailure.integrity }
        let volume = try await store.volume()
        if publisher == nil { publisher = ManagedManifestPublisher(remote: remote, prefix: prefix, volumeID: volume.id) }
        guard let publisher else { throw StorageFailure.integrity }
        var payloads: [NodeID: NamespaceOperation] = [:]
        for op in batch {
            if op.kind == .write { payloads[op.nodeID] = op }
            else if op.kind == .create, op.nodeSnapshot?.kind == .file, payloads[op.nodeID] == nil { payloads[op.nodeID] = op }
        }
        let candidates = payloads.values.sorted { $0.sequence < $1.sequence }
        var objects: [NodeID: StorageObject] = [:]
        try pauseBoundary()
        let results = await EngineTrace.measure("batch.uploadPayloads(\(candidates.count))") { await ManagedUploadPipeline.run(sizes: candidates.map { $0.nodeSnapshot?.size ?? 0 }, maximumFiles: managedUploadConcurrency,
            shouldContinue: { [self] in await self.canPrepareManagedPayload() },
            prepare: { [self] index in
                let op = candidates[index]
                guard let node = op.nodeSnapshot else { throw StorageFailure.integrity }
                return try await prepareManagedContent(op, node: node)
            }) }
        // Preserve deterministic error reporting and never publish a partial
        // frozen batch after failed/stopped admission.
        for (index, op) in candidates.enumerated() {
            if let result = results[index] { objects[op.nodeID] = try result.get() }
        }
        try pauseBoundary()
        guard objects.count == candidates.count else { throw StorageFailure.integrity }
        let publication: ManagedPublication
        if let saved: ManagedPublication = try await savedReceipt(first, step: "managed-batch-intent") { publication = saved }
        else {
            var updates: [NodeID: ManagedNodeRecord] = [:]
            for op in batch {
                for parent in op.parentSnapshots ?? [] { updates[parent.id] = ManagedNodeRecord(node: parent) }
                guard let node = op.nodeSnapshot else { throw StorageFailure.integrity }
                let backing: ObjectLocator?
                if let object = objects[node.id] { backing = locator(object) }
                else { backing = try await store.publishedLocator(nodeID: node.id, generation: node.contentGeneration) ?? node.backing }
                updates[node.id] = ManagedNodeRecord(node: node, backing: backing)
            }
            if try await publisher.load() == nil, updates[volume.rootID] == nil {
                updates[volume.rootID] = ManagedNodeRecord(node: try await store.retainedNode(volume.rootID))
            }
            publication = try await EngineTrace.measure("publisher.prepare") { try await publisher.prepare(revision: last.sequence, operationIDs: batch.map(\.id),
                updates: updates.values.sorted { $0.id.uuidString < $1.id.uuidString }) }
            try await receipt(first, step: "managed-batch-intent", value: publication)
        }
        try pauseBoundary()
        try await EngineTrace.measure("publisher.publish") { try await publisher.publish(publication, operationID: first.id) }
        try await EngineTrace.measure("markPublished(\(candidates.count))") { for op in candidates {
            guard let object = objects[op.nodeID] else { throw StorageFailure.integrity }
            try await markPublishedIfCurrent(nodeID: op.nodeID, generation: op.kind == .write ? op.targetGeneration : 0, object: object)
        } }
    }

    private func canPrepareManagedPayload() -> Bool { !pauseRequested }

    private func processManaged(_ operation: NamespaceOperation) async throws {
        let volume = try await store.volume()
        if publisher == nil { publisher = ManagedManifestPublisher(remote: remote, prefix: prefix, volumeID: volume.id) }
        guard let publisher else { throw StorageFailure.integrity }
        let node: NamespaceNode
        if let snapshot = operation.nodeSnapshot { node = snapshot }
        else { node = try await store.retainedNode(operation.nodeID) }
        var backing = try await store.publishedLocator(nodeID: node.id, generation: node.contentGeneration) ?? node.backing
        if operation.kind == .write || (operation.kind == .create && node.kind == .file) {
            backing = locator(try await prepareManagedContent(operation, node: node))
        }
        let publication: ManagedPublication
        if let saved: ManagedPublication = try await savedReceipt(operation, step: "managed-intent") { publication = saved }
        else {
            if operation.kind == .remove { publication = try await publisher.prepare(revision: operation.sequence, operationIDs: [operation.id], updates: (operation.parentSnapshots?.map { ManagedNodeRecord(node: $0) } ?? []) + [ManagedNodeRecord(node: node)]) }
            else {
                var record = ManagedNodeRecord(node: node, backing: backing)
                // Serialize accepted history in operation order, not a later local rename.
                if let destination = operation.destinationPath { record.name = String(destination.split(separator: "/").last ?? "") }
                var updates = operation.parentSnapshots?.map { ManagedNodeRecord(node: $0) } ?? []
                if try await publisher.load() == nil {
                    let root = try await store.retainedNode(volume.rootID)
                    if !updates.contains(where: { $0.id == root.id }) { updates.append(ManagedNodeRecord(node: root)) }
                }
                updates.removeAll { $0.id == record.id }; updates.append(record)
                publication = try await publisher.prepare(revision: operation.sequence, operationIDs: [operation.id], updates: updates, removals: operation.replacedNodeID.map { [$0] } ?? [])
            }
            try await receipt(operation, step: "managed-intent", value: publication)
        }
        try pauseBoundary()
        try await publisher.publish(publication, operationID: operation.id)
        if let backing, operation.kind == .write || operation.kind == .create { try await markPublishedIfCurrent(nodeID: node.id, generation: operation.kind == .write ? operation.targetGeneration : 0, object: StorageObject(key: backing.key, size: backing.size, validator: backing.validator ?? "", checksum: backing.checksum)) }
    }
    private func expectedObject(operation: NamespaceOperation, key: String) async throws -> StorageObject? {
        let generation = operation.kind == .write ? operation.baseGeneration : operation.nodeSnapshot?.contentGeneration
        var candidates = [ObjectLocator]()
        if let generation, let published = try await store.publishedLocator(nodeID: operation.nodeID, generation: generation) { candidates.append(published) }
        if let source = operation.sourceLocator { candidates.append(source) }
        for candidate in candidates {
            if candidate.key == key, let validator = candidate.validator { return StorageObject(key: key, size: candidate.size, validator: validator, checksum: candidate.checksum) }
            let resolved = try await content.resolve(candidate)
            if resolved.key == key, let validator = resolved.validator { return StorageObject(key: key, size: resolved.size, validator: validator, checksum: resolved.checksum) }
        }
        var pending = operation.dependencies, seen = Set<UUID>()
        while let id = pending.popLast() {
            guard seen.insert(id).inserted, seen.count <= 10_000 else { throw StorageFailure.integrity }
            guard let previous = try await store.operation(id) else { throw StorageFailure.integrity }
            if previous.nodeID == operation.nodeID {
                // Directory markers have no published content locator. Their
                // original upload proof must follow verified rename/metadata
                // aliases before a later conditional remove or metadata edit.
                for step in ["modified", "uploaded"] {
                    if let object: StorageObject = try await savedReceipt(previous, step: step) {
                        let resolved = try await content.resolve(locator(object))
                        if resolved.key == key, let validator = resolved.validator {
                            return StorageObject(key: key, size: resolved.size, validator: validator, checksum: resolved.checksum)
                        }
                        if object.key == key { return object }
                    }
                }
            }
            pending.append(contentsOf: previous.dependencies)
        }
        return nil
    }
    private func markPublishedIfCurrent(nodeID: NodeID, generation: Int64, object: StorageObject) async throws {
        do { try await store.recordPublishedContent(nodeID: nodeID, generation: generation, backing: locator(object)) }
        catch NamespaceFailure.generationChanged { /* A newer accepted generation remains dirty. */ }
    }
    private func putReconciled(key: String, data: Data, condition: StorageCondition, operation: NamespaceOperation) async throws -> StorageObject {
        if let object: StorageObject = try await savedReceipt(operation, step: "uploaded") { guard let actual = try await remote.head(key: key), same(actual, object) else { throw StorageFailure.conflict }; return object }
        do { return try await remote.put(key: key, data: data, condition: condition, operationID: operation.id) }
        catch { guard let object = try await remote.head(key: key), object.operationID == operation.id, object.size == data.count, object.checksum == CoreFileIO.hash(data) else { throw error }; return object }
    }
    private func subtree(_ id: NodeID, recursive: Bool) async throws -> [NamespaceNode] {
        let root = try await store.node(id)
        guard recursive, root.kind == .directory else { return [root] }
        var result = [root], queue = [id], index = 0
        while index < queue.count {
            let parent = queue[index]; index += 1; var cursor: String?
            repeat {
                let page = try await store.list(parentID: parent, after: cursor, limit: 256)
                result.append(contentsOf: page.nodes); queue.append(contentsOf: page.nodes.filter { $0.kind == .directory }.map(\.id))
                guard result.count <= 1_000_000 else { throw StorageFailure.localStorageFull }
                cursor = page.next
            } while cursor != nil
        }
        return result
    }
    private func readPage(_ id: UUID, in directory: URL) throws -> [RelocationObject] {
        let values = try CoreFileIO.readChecked([RelocationObject].self, at: directory.appendingPathComponent(id.uuidString + ".json"), maximum: 512 * 1024)
        guard values.count <= 128 else { throw StorageFailure.integrity }; return values
    }
    private func receipt<T: Codable & Equatable>(_ operation: NamespaceOperation, step: String, value: T) async throws {
        // Older records used JSONEncoder's unspecified dictionary order. Compare
        // decoded proofs before replay, not their incidental serialized bytes.
        if let previous: T = try await savedReceipt(operation, step: step) {
            guard previous == value else { throw NamespaceFailure.generationChanged }; return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value); guard data.count <= 256 * 1024 else { throw StorageFailure.integrity }
        try await store.recordReceipt(operationID: operation.id, stepID: step, validator: data.base64EncodedString())
    }
    private func savedReceipt<T: Decodable>(_ operation: NamespaceOperation, step: String) async throws -> T? {
        guard let value = try await store.receipts(operationID: operation.id).first(where: { $0.stepID == step })?.validator else { return nil }
        guard let data = Data(base64Encoded: value), data.count <= 256 * 1024 else { throw StorageFailure.integrity }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func remoteKey(_ path: String?) throws -> String {
        guard let path, !path.isEmpty, !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw StorageFailure.integrity }
        return prefix + "/" + path
    }
    private func locator(_ object: StorageObject) -> ObjectLocator { .init(key: object.key, validator: object.validator, size: object.size, checksum: object.checksum) }
    private func same(_ a: StorageObject, _ b: StorageObject) -> Bool { a.key == b.key && a.size == b.size && a.validator == b.validator && (a.checksum == nil || a.checksum == b.checksum) }
    private struct MutationFingerprint: Codable {
        var kind: String
        var nodeID: UUID
        var offset: Int64?
        var size: Int64?
        var payloadSHA256: String?
    }
    private func mutationFingerprint(kind: String, nodeID: UUID, offset: Int64? = nil, size: Int64? = nil, payloadSHA256: String? = nil) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = MutationFingerprint(kind: kind, nodeID: nodeID, offset: offset, size: size,
                                        payloadSHA256: payloadSHA256)
        return CoreFileIO.hash(try encoder.encode(value))
    }
    private func replayMutation(_ id: UUID?, nodeID: NodeID, fingerprint: String) async throws -> NamespaceNode? {
        guard let id else { return nil }
        if let noop = try await content.noopResponse(id: id, fingerprint: fingerprint, nodeID: nodeID) { return noop }
        guard let operation = try await store.operation(id) else { return nil }
        guard operation.kind == .write, operation.nodeID == nodeID, let snapshotID = operation.stagedSnapshotID else { throw NamespaceFailure.invalidTransition }
        let saved = try await store.receipts(operationID: id).first { $0.stepID == "mutation-fingerprint" }?.validator
        if let saved { guard saved == fingerprint else { throw NamespaceFailure.invalidTransition } }
        else {
            let snapshot = try await content.snapshot(id: snapshotID)
            guard snapshot.mutationFingerprint == fingerprint else { throw NamespaceFailure.invalidTransition }
            try await store.recordReceipt(operationID: id, stepID: "mutation-fingerprint", validator: fingerprint)
        }
        guard let result = operation.nodeSnapshot else { throw StorageFailure.integrity }
        return result
    }
    private func pauseBoundary() throws { if pauseRequested { throw Control.pauseRequested } }
    private func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 { let sum = a.addingReportingOverflow(b); return sum.overflow ? Int64.max : sum.partialValue }
    private func classify(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? StorageFailure { return String(describing: failure) }
        if let failure = error as? NamespaceFailure { return String(describing: failure) }
        return "remoteUnavailable"
    }
}
