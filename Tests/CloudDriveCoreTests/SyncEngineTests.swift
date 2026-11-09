import XCTest
import Foundation
@testable import CloudDriveCore

private actor FaultStorage: StorageRemote {
    struct Value { var object: StorageObject; var data: Data }
    var values: [String: Value] = [:]
    var sequence = 0
    var reads = 0
    var copies = 0
    var deletes = 0
    var failDelete = false
    var loseDelete = false
    var loseHeadPut = false
    var invalidRanges = false
    var readDelay = false
    var listDelay = false
    var mutateAfterCopy = false
    var dropCopyChecksum = false
    var loseMetadataReply = false
    var puts = 0
    var uploads = 0
    var headWrites = 0
    var metadataWrites = 0
    var uploadDelay = false
    var activeUploads = 0
    var peakUploads = 0
    var transportOffline = false
    private var holdNextHead = false
    private var blockedHead: CheckedContinuation<Void, Never>?
    func blockNextPublication() { holdNextHead = true }
    func publicationIsBlocked() -> Bool { blockedHead != nil }
    func releasePublication() { blockedHead?.resume(); blockedHead = nil }
    func setOffline(_ offline: Bool) { transportOffline = offline }
    var rejectHead = false
    func configure(failDelete: Bool? = nil, loseDelete: Bool? = nil, loseHeadPut: Bool? = nil, invalidRanges: Bool? = nil, readDelay: Bool? = nil, listDelay: Bool? = nil, mutateAfterCopy: Bool? = nil, dropCopyChecksum: Bool? = nil, loseMetadataReply: Bool? = nil, uploadDelay: Bool? = nil) {
        if let failDelete { self.failDelete = failDelete }; if let loseDelete { self.loseDelete = loseDelete }
        if let loseHeadPut { self.loseHeadPut = loseHeadPut }; if let invalidRanges { self.invalidRanges = invalidRanges }
        if let readDelay { self.readDelay = readDelay }; if let listDelay { self.listDelay = listDelay }
        if let mutateAfterCopy { self.mutateAfterCopy = mutateAfterCopy }; if let dropCopyChecksum { self.dropCopyChecksum = dropCopyChecksum }; if let loseMetadataReply { self.loseMetadataReply = loseMetadataReply }; if let uploadDelay { self.uploadDelay = uploadDelay }
    }
    func startedUploads() -> Int { uploads }
    func uploadPeak() -> Int { peakUploads }
    func publicationCounters() -> (heads: Int, pages: Int) { (headWrites, metadataWrites) }
    func rejectPublications(_ value: Bool) { rejectHead = value }
    func counters() -> (Int, Int, Int, Int) { (reads, copies, deletes, puts) }
    func bytes(_ key: String) -> Data? { values[key]?.data }
    func keys() -> [String] { values.keys.sorted() }
    func seed(_ key: String, _ data: Data) throws -> StorageObject { try storePut(key: key, data: data, condition: .unconditional, operationID: UUID()) }
    func head(key: String) -> StorageObject? { values[key]?.object }
    func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange {
        reads += 1
        if transportOffline { throw StorageFailure.offline }
        if readDelay { try await Task.sleep(for: .milliseconds(30)) }
        guard let value = values[key] else { throw StorageFailure.notFound }
        guard value.object.validator == validator else { throw StorageFailure.conflict }
        guard range.lowerBound >= 0, range.upperBound <= value.object.size else { throw StorageFailure.invalidRange }
        return .init(data: value.data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), offset: range.lowerBound + (invalidRanges ? 1 : 0), totalSize: value.object.size, validator: validator)
    }
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject {
        if holdNextHead && key.hasSuffix("/HEAD") {
            holdNextHead = false
            await withCheckedContinuation { blockedHead = $0 }
        }
        return try storePut(key: key, data: data, condition: condition, operationID: operationID)
    }
    private func storePut(key: String, data: Data, condition: StorageCondition, operationID: UUID) throws -> StorageObject {
        if transportOffline { throw StorageFailure.offline }
        if rejectHead && key.hasSuffix("/HEAD") { throw StorageFailure.conflict }
        switch condition {
        case .absent: guard values[key] == nil else { throw StorageFailure.conflict }
        case .matches(let validator): guard values[key]?.object.validator == validator else { throw StorageFailure.conflict }
        case .unconditional: break
        }
        sequence += 1; puts += 1
        if key.hasSuffix("/HEAD") { headWrites += 1 }
        if key.contains("/.clouddrive/v1/metadata/") { metadataWrites += 1 }
        let object = StorageObject(key: key, size: Int64(data.count), validator: "v\(sequence)", checksum: CoreFileIO.hash(data), operationID: operationID)
        values[key] = .init(object: object, data: data)
        if key.hasSuffix("/HEAD"), loseHeadPut { loseHeadPut = false; throw StorageFailure.unknownOutcome }
        return object
    }
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) throws -> StorageObject {
        guard let value = values[source], value.object.validator == sourceValidator else { throw StorageFailure.conflict }
        copies += 1
        let object = try storePut(key: destination, data: value.data, condition: .absent, operationID: operationID)
        if mutateAfterCopy { mutateAfterCopy = false; _ = try seed(source, Data("external changed".utf8)) }
        if dropCopyChecksum { var changed = object; changed.checksum = nil; values[destination] = .init(object: changed, data: value.data); return changed }
        return object
    }
    func delete(key: String, validator: String) throws {
        guard !failDelete else { throw StorageFailure.unsupported }
        guard let value = values[key] else { return }
        guard value.object.validator == validator else { throw StorageFailure.conflict }
        values.removeValue(forKey: key); deletes += 1
        if loseDelete { loseDelete = false; throw StorageFailure.unknownOutcome }
    }
    func setModifiedAt(key: String, validator: String, date: Date, operationID: UUID) throws -> StorageObject {
        guard var value = values[key], value.object.validator == validator else { throw StorageFailure.conflict }
        sequence += 1; value.object.validator = "v\(sequence)"; value.object.operationID = operationID; value.object.modifiedAt = date
        values[key] = value
        if loseMetadataReply { loseMetadataReply = false; throw StorageFailure.unknownOutcome }
        return value.object
    }
    func upload(key: String, size: Int64, condition: StorageCondition, operationID: UUID,
                reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        guard size >= 0, size <= 64 * 1024 * 1024 else { throw StorageFailure.unsupported }
        uploads += 1; activeUploads += 1; peakUploads = max(peakUploads, activeUploads)
        defer { activeUploads -= 1 }
        if uploadDelay { try await Task.sleep(for: .milliseconds(100)) }
        var bytes = Data(), offset: Int64 = 0
        while offset < size {
            let end = min(size, offset + 16 * 1024 * 1024), chunk = try await reader(offset..<end)
            guard chunk.count == end - offset else { throw StorageFailure.invalidResponse }
            bytes.append(chunk); offset = end
        }
        return try storePut(key: key, data: bytes, condition: condition, operationID: operationID)
    }
    func list(prefix: String, cursor: String?, limit: Int) async throws -> StoragePage {
        if listDelay { try await Task.sleep(for: .milliseconds(200)) }
        let objects = values.values.map(\.object).filter { $0.key.hasPrefix(prefix) && (cursor == nil || $0.key > cursor!) }.sorted { $0.key < $1.key }
        let result = Array(objects.prefix(limit))
        return .init(objects: result, nextCursor: objects.count > limit ? result.last?.key : nil)
    }
}

final class SyncEngineTests: XCTestCase {
    func testManagedBatchPublishesSixFinderFilesWithOneHeadAndTwoPages() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let parent = try await store.volume().rootID
        var nodes: [NamespaceNode] = []
        var held: NamespaceNode?, lease: UUID?
        for i in 0..<6 {
            let node = try await store.create(parentID: parent, name: "batch-\(i)", kind: .file, nativeXattrs: true)
            nodes.append(node)
            let first = try await engine.write(nodeID: node.id, offset: 0, data: Data([UInt8(i)]))
            if i == 0 { held = first; lease = await engine.retain(node: first) }
            _ = try await engine.write(nodeID: node.id, offset: 1, data: Data([42]))
            _ = try await store.setXattr(nodeID: node.id, name: "com.apple.provenance", value: Data([7]), policy: "set", operationID: UUID())
        }
        try await engine.processPending(limit: 128)
        let counts = await remote.publicationCounters(), uploads = await remote.startedUploads()
        XCTAssertEqual(counts.heads, 1); XCTAssertEqual(counts.pages, 2); XCTAssertEqual(uploads, 6)
        let state = try await engine.status(); XCTAssertEqual(state.pending, 0)
        let oldBytes = try await engine.read(node: XCTUnwrap(held), offset: 0, length: 1)
        XCTAssertEqual(oldBytes, Data([0]))
        await engine.release(token: try XCTUnwrap(lease))
        let restored = try await NamespaceRecovery.restoreManaged(remote: remote, prefix: "Drive", directory: root.appendingPathComponent("cold"), binding: "cold")
        for (i, node) in nodes.enumerated() {
            let record = try await restored.node(node.id)
            XCTAssertEqual(record.xattrs?["com.apple.provenance"], Data([7]))
            let backing = try XCTUnwrap(record.backing), validator = try XCTUnwrap(backing.validator)
            let cloudBytes = try await remote.read(key: backing.key, range: 0..<backing.size, validator: validator)
            XCTAssertEqual(cloudBytes.data, Data([UInt8(i), 42]))
            let bytes = try await engine.read(nodeID: node.id, offset: 0, length: 2)
            XCTAssertEqual(bytes, Data([UInt8(i), 42]))
            XCTAssertEqual(record.contentGeneration, 2)
        }
        await restored.close(); await store.close()
    }

    func testManagedBatchReplaysAfterRemoteCommitAndLocalCompletionRollback() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, cache, engine) = try setup(root, remote: remote, mode: .managed)
        let parent = try await store.volume().rootID
        let one = try await store.create(parentID: parent, name: "one", kind: .file)
        _ = try await engine.write(nodeID: one.id, offset: 0, data: Data([1]))
        let two = try await store.create(parentID: parent, name: "two", kind: .file)
        _ = try await engine.write(nodeID: two.id, offset: 0, data: Data([2]))
        await store.rejectBatchCompletionForTesting(true)
        do { try await engine.processPending(); XCTFail("Local completion must fail") } catch NamespaceFailure.storage {}
        let failed = try await store.volume(), uploaded = await remote.startedUploads(), counts = await remote.publicationCounters()
        XCTAssertEqual(failed.publishedRevision, 0); XCTAssertEqual(counts.heads, 1); XCTAssertEqual(uploaded, 2)
        let pending = try await store.operations(); XCTAssertEqual(pending.count, 4)
        XCTAssertFalse(pending.contains { $0.state == .complete })
        await store.rejectBatchCompletionForTesting(false)
        _ = try await engine.write(nodeID: one.id, offset: 1, data: Data([9]))
        await store.close()
        let reopened = try NamespaceStore(directory: root.appendingPathComponent("namespace"), binding: "synthetic", mode: .managed)
        let resumed = SyncEngine(store: reopened, content: content, cache: cache, remote: remote, prefix: "Drive", mode: .managed)
        try await resumed.resume()
        let state = try await resumed.status(), bytes = try await resumed.read(nodeID: one.id, offset: 0, length: 2)
        let afterUploads = await remote.startedUploads()
        XCTAssertEqual(state.pending, 0); XCTAssertEqual(state.localRevision, state.publishedRevision)
        XCTAssertEqual(bytes, Data([1, 9])); XCTAssertEqual(afterUploads, 3)
        await reopened.close()
    }

    func testManagedBatchesStayBoundedAndRespectRenameRemoveBarriersWithLostHeadReply() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        var nodes: [NamespaceNode] = []
        for i in 0..<40 { nodes.append(try await store.create(parentID: volume.rootID, name: "item-\(i)", kind: .file, nativeXattrs: true)) }
        _ = try await store.rename(nodeID: nodes[0].id, parentID: volume.rootID, name: "renamed")
        _ = try await store.setXattr(nodeID: nodes[0].id, name: "com.apple.provenance", value: Data([9]), policy: "set", operationID: UUID())
        _ = try await store.remove(nodeID: nodes[1].id)
        await remote.configure(loseHeadPut: true)
        try await engine.synchronize(waitForCloud: true)
        let counts = await remote.publicationCounters()
        XCTAssertEqual(counts.heads, 5, "Two bounded create batches, then ordered rename, metadata and remove")
        let publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        let old = try await publisher.lookup(parentID: volume.rootID, name: "item-0")
        let removed = try await publisher.lookup(parentID: volume.rootID, name: "item-1")
        let renamed = try await publisher.lookup(parentID: volume.rootID, name: "renamed")
        XCTAssertNil(old); XCTAssertNil(removed); XCTAssertEqual(renamed?.id, nodes[0].id)
        XCTAssertEqual(renamed?.xattrs?["com.apple.provenance"], Data([9]))
        let state = try await engine.status(); XCTAssertEqual(state.pending, 0)
        await store.close()
    }

    func testManagedBulkTrieUpdatesRewriteSharedAncestorsOnce() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        try await store.importEntries((0..<128).map { .init(path: "file-\($0)", size: 0) })
        try await engine.publishInitialNamespace()
        let volume = try await store.volume(), publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        var changes: [ManagedNodeRecord] = []
        for i in 0..<128 {
            let found = try await store.lookup(parentID: volume.rootID, name: "file-\(i)")
            let node = try XCTUnwrap(found)
            var record = ManagedNodeRecord(node: node); record.modifiedAt = Date(timeIntervalSince1970: 1234)
            changes.append(record)
        }
        let before = await remote.publicationCounters()
        let publication = try await publisher.prepare(revision: volume.revision + 1, operationIDs: [UUID()], updates: changes)
        try await publisher.publish(publication, operationID: publication.commit.operationIDs[0])
        let after = await remote.publicationCounters()
        XCTAssertLessThanOrEqual(after.pages - before.pages, 40, "Shared trie ancestors must not be rewritten for every file")
        XCTAssertEqual(after.heads - before.heads, 1)
        let cold = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        for change in changes {
            let record = try await cold.node(id: change.id)
            XCTAssertEqual(record?.modifiedAt, change.modifiedAt)
        }
        await store.close()
    }
    func testVerifiedWritebackCacheSharesFetchesAndEvictsWithoutTrustingBadResponses() async throws {
        let remote = FaultStorage(), cache = VerifiedCloudObjectCache(maximumBytes: 4)
        let one = try await remote.seed("one", Data([1, 2, 3, 4]))
        let two = try await remote.seed("two", Data([5, 6, 7, 8]))
        await remote.configure(readDelay: true)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<16 {
                group.addTask { try await cache.read(key: one.key, size: one.size, validator: one.validator,
                                                    checksum: one.checksum!, remote: remote) }
            }
            for try await data in group { XCTAssertEqual(data, Data([1, 2, 3, 4])) }
        }
        var count = await remote.counters().0
        XCTAssertEqual(count, 1, "Concurrent and subsequent small reads must share a verified object")
        await remote.configure(invalidRanges: true)
        for _ in 0..<2 {
            do {
                _ = try await cache.read(key: two.key, size: two.size, validator: two.validator, checksum: two.checksum!, remote: remote)
                XCTFail("Invalid response must never enter the cache")
            } catch StorageFailure.integrity {}
        }
        count = await remote.counters().0; XCTAssertEqual(count, 3)
        await remote.configure(invalidRanges: false)
        _ = try await cache.read(key: two.key, size: two.size, validator: two.validator, checksum: two.checksum!, remote: remote)
        _ = try await cache.read(key: one.key, size: one.size, validator: one.validator, checksum: one.checksum!, remote: remote)
        count = await remote.counters().0
        XCTAssertEqual(count, 5, "Evicted data must be fetched and verified again")
        do {
            _ = try await cache.read(key: one.key, size: one.size, validator: one.validator, checksum: "wrong", remote: remote)
            XCTFail("A checksum change cannot reuse a differently verified object")
        } catch StorageFailure.integrity {}
        let replaced = try await remote.seed("one", Data([9, 9, 9, 9]))
        let changed = try await cache.read(key: replaced.key, size: replaced.size, validator: replaced.validator,
                                          checksum: replaced.checksum!, remote: remote)
        XCTAssertEqual(changed, Data([9, 9, 9, 9]))
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func setup(_ directory: URL, remote: FaultStorage, mode: NamespaceStorageMode = .compatible, stagingBudget: Int64 = 1_000_000) throws -> (NamespaceStore, ContentStore, RangeCache, SyncEngine) {
        let store = try NamespaceStore(directory: directory.appendingPathComponent("namespace"), binding: "synthetic", mode: mode)
        let content = try ContentStore(directory: directory.appendingPathComponent("content"), maximumBytes: stagingBudget)
        let cache = try RangeCache(directory: directory.appendingPathComponent("cache"), maximumBytes: 8192, chunkSize: 4096)
        return (store, content, cache, SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: "Drive", mode: mode))
    }
    private func required<T>(_ value: T?) throws -> T { guard let value else { XCTFail("Missing expected fixture value"); throw StorageFailure.notFound }; return value }
    private func locator(_ object: StorageObject) -> ObjectLocator { .init(key: object.key, validator: object.validator, size: object.size, checksum: object.checksum) }

    func testCommittedManagedWriteSurvivesKilledOwnerWithLiveWAL() async throws {
        let envKey = "CLOUDDRIVE_KILLED_OWNER_TEST_DIRECTORY"
        let payload = Data(repeating: 87, count: 1024 * 1024)
        let operationID = try XCTUnwrap(UUID(uuidString: "A20E0A49-8126-464C-85A1-C1B2F9913577"))
        if let path = ProcessInfo.processInfo.environment[envKey] {
            let directory = URL(fileURLWithPath: path)
            let (store, _, _, engine) = try setup(directory, remote: FaultStorage(), mode: .managed, stagingBudget: 8 * 1024 * 1024)
            let node = try await store.create(parentID: store.volume().rootID, name: "committed", kind: .file)
            _ = try await engine.write(node: node, offset: 0, data: payload, operationID: operationID, bufferedHandle: true)
            // Keep the open SQLite handles alive until SIGKILL; a clean close
            // checkpoints WAL and would fail to exercise crash recovery.
            withExtendedLifetime((store, engine)) { _ = kill(getpid(), SIGKILL) }
            XCTFail("Expected abrupt child process exit")
            return
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "CloudDriveCoreTests.SyncEngineTests/testCommittedManagedWriteSurvivesKilledOwnerWithLiveWAL",
                           Bundle(for: SyncEngineTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[envKey] = root.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(30)
        while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !child.isRunning else { kill(child.processIdentifier, SIGKILL); throw POSIXError(.ETIMEDOUT) }
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
        XCTAssertGreaterThan(try CoreFileIO.regularSize(root.appendingPathComponent("namespace/namespace.sqlite-wal")), 0)
        let (store, _, _, engine) = try setup(root, remote: FaultStorage(), mode: .managed, stagingBudget: 8 * 1024 * 1024)
        let node = try required(try await store.lookup(parentID: store.volume().rootID, name: "committed"))
        let actual = try await engine.read(nodeID: node.id, offset: 0, length: payload.count)
        XCTAssertEqual(actual, payload)
        let original = try required(try await store.operation(operationID))
        let replay = try await engine.write(node: node, offset: 0, data: payload, operationID: operationID)
        XCTAssertEqual(original.nodeSnapshot, replay)
        let receipts = try await store.receipts(operationID: operationID)
        XCTAssertTrue(receipts.contains { $0.stepID == "mutation-fingerprint" })
    }

    func testOpenFinderWriteWindowSealsBeforePublicationAndRecoversLostReply() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage()
        let (store, _, _, engine) = try setup(root, remote: remote, mode: .managed, stagingBudget: 256 * 1024 * 1024)
        guard await store.admissionFenceDirectory != nil else { throw XCTSkip("APFS media barrier required") }
        let node = try await store.create(parentID: store.volume().rootID, name: "buffered", kind: .file)
        let chunk = Data(repeating: 19, count: 1024 * 1024)
        let identity = UUID()
        await store.injectBrokenAdmissionFence(true)
        // The private WAL and immutable content are written to the kernel, but
        // there is no hardware-fence requirement before this open-file write.
        _ = try await engine.write(node: node, offset: 0, data: chunk, operationID: identity, bufferedHandle: true)
        do { try await engine.processPending(); XCTFail("Published through a failed hardware fence") }
        catch StorageFailure.integrity {}
        let keys = await remote.keys()
        XCTAssertEqual(keys, [])
        do { try await engine.synchronize(); XCTFail("Reported successful fsync through a failed hardware fence") }
        catch StorageFailure.integrity {}
        do { _ = try await engine.write(node: node, offset: 0, data: chunk, operationID: identity); XCTFail("Replay bypassed a failed fence") }
        catch StorageFailure.integrity {}
        await store.injectBrokenAdmissionFence(false)
        try await engine.synchronize()
        let replay = try await engine.write(node: node, offset: 0, data: chunk, operationID: identity)
        XCTAssertEqual(replay.contentGeneration, 1)
        let read = try await engine.read(nodeID: node.id, offset: 0, length: chunk.count)
        XCTAssertEqual(read, chunk)
    }

    func testOpenFinderWindowIsBoundedAndVisibleAfterSeal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _, engine) = try setup(root, remote: FaultStorage(), mode: .managed, stagingBudget: 256 * 1024 * 1024)
        guard await store.admissionFenceDirectory != nil else { throw XCTSkip("APFS media barrier required") }
        let node = try await store.create(parentID: store.volume().rootID, name: "window", kind: .file)
        let payload = Data(repeating: 102, count: 1024 * 1024)
        let start = Date()
        for i in 0..<64 {
            _ = try await engine.write(node: node, offset: Int64(i * payload.count), data: payload, operationID: UUID(), bufferedHandle: true)
        }
        try await engine.synchronize()
        print("BUFFERED_FINDER_64MiB ms=", Date().timeIntervalSince(start) * 1000)
        let read = try await engine.read(nodeID: node.id, offset: Int64(63 * payload.count), length: payload.count)
        XCTAssertEqual(read, payload)
        // A single write of the maximum window must be fully fenced immediately.
        await store.injectBrokenAdmissionFence(true)
        do {
            _ = try await engine.write(node: node, offset: Int64(64 * payload.count),
                data: Data(repeating: 7, count: NamespaceDatabase.writeWindow), operationID: UUID(), bufferedHandle: true)
            XCTFail("Accepted a complete unfenced window")
        } catch StorageFailure.integrity {}
        await store.injectBrokenAdmissionFence(false)
        try await engine.synchronize()
    }

    func testManagedWriteBarrierBeforePublicationAndUnsupportedFallback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, content, _, engine) = try setup(root, remote: FaultStorage(), mode: .managed, stagingBudget: 8 * 1024 * 1024)
        let extents = root.appendingPathComponent("content/extents"), snapshots = root.appendingPathComponent("content/snapshots")
        guard CoreFileIO.sameAPFSVolume(extents, snapshots) else { throw XCTSkip("Grouped write fences require same-device APFS") }
        let node = try await store.create(parentID: store.volume().rootID, name: "barrier", kind: .file)
        let payload = Data(repeating: 91, count: 8192), id = UUID()
        await content.configureWriteBarrierForTesting(enabled: true) { _ in
            let manifestFiles = try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
            XCTAssertFalse(manifestFiles.contains { $0.pathExtension == "json" })
            let files = try FileManager.default.contentsOfDirectory(at: extents, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), payload)
            throw StorageFailure.integrity
        }
        do { _ = try await engine.write(node: node, offset: 0, data: payload, operationID: id); XCTFail("Failed barrier acknowledged data") }
        catch StorageFailure.integrity {}
        let afterFailure = try await store.node(node.id), missing = try await store.operation(id)
        XCTAssertNil(missing); XCTAssertEqual(afterFailure.size, 0); XCTAssertEqual(afterFailure.contentGeneration, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        XCTAssertTrue(names.isEmpty)
        await content.configureWriteBarrierForTesting(enabled: true) { _ in throw POSIXError(.ENOTSUP) }
        let accepted = try await engine.write(node: node, offset: 0, data: payload, operationID: id)
        XCTAssertEqual(accepted.contentGeneration, 1)
        let read = try await engine.read(nodeID: node.id, offset: 0, length: payload.count)
        XCTAssertEqual(read, payload)
    }

    func testManagedPairedExtentFenceTiming() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var writers: [(SyncEngine, NamespaceNode)] = []
        for enabled in [false, true] {
            let location = root.appendingPathComponent(enabled ? "grouped" : "separate")
            let (store, content, _, engine) = try setup(location, remote: FaultStorage(), mode: .managed, stagingBudget: 256 * 1024 * 1024)
            guard CoreFileIO.sameAPFSVolume(location.appendingPathComponent("content/extents"), location.appendingPathComponent("content/snapshots")) else {
                throw XCTSkip("Paired write fences require APFS")
            }
            await content.configureWriteBarrierForTesting(enabled: enabled)
            let node = try await store.create(parentID: store.volume().rootID, name: "paired", kind: .file)
            writers.append((engine, node))
        }
        let payload = Data(repeating: 109, count: 1024 * 1024)
        var times = [[Double](), [Double]()]
        for i in 0..<64 {
            for side in (i.isMultiple(of: 2) ? [0,1] : [1,0]) {
                let (engine, node) = writers[side], start = Date()
                _ = try await engine.write(node: node, offset: Int64(i * payload.count), data: payload, operationID: UUID())
                times[side].append(Date().timeIntervalSince(start) * 1000)
            }
        }
        for side in [0,1] {
            let (engine, node) = writers[side]
            let result = try await engine.read(nodeID: node.id, offset: Int64(63 * payload.count), length: payload.count)
            XCTAssertEqual(result, payload)
            print("MANAGED_PAIRED_64MiB grouped=", side == 1, "median_ms=",times[side].sorted()[32], "total_ms=", times[side].reduce(0,+))
        }
    }

    func testManagedSequentialWriteCostAndReceiptReplay() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote, mode: .managed, stagingBudget: 256 * 1024 * 1024)
        let node = try await store.create(parentID: store.volume().rootID, name: "sequential", kind: .file)
        let payload = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        var request = UUID(), first: NamespaceNode?, samples: [Double] = []
        for index in 0..<64 {
            let operation = UUID(), start = Date()
            let result = try await engine.write(node: node, offset: Int64(index * payload.count), data: payload, operationID: operation)
            samples.append(Date().timeIntervalSince(start) * 1000)
            if index == 0 { request = operation; first = result }
        }
        let flat = Array(samples[0..<32]).sorted(), indexed = Array(samples[34..<64]).sorted()
        print("MANAGED_WRITE_COST flat_median_ms=", flat[flat.count / 2], "indexed_median_ms=", indexed[indexed.count / 2], "total_ms=", samples.reduce(0,+))
        let replay = try await engine.write(node: node, offset: 0, data: payload, operationID: request)
        XCTAssertEqual(replay.contentGeneration, first?.contentGeneration)
        let accounting = await content.accounting()
        XCTAssertEqual(accounting.snapshotCount, 64)
        let receipts = try await store.receipts(operationID: request)
        XCTAssertTrue(receipts.contains(where: { $0.stepID == "mutation-fingerprint" }))
    }
    func testManagedFinderXattrsSurviveRenameRetryAndColdRestoreWithoutTakingLegacySidecars() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote, mode: .managed)
        let legacyData = try await remote.seed("Drive/legacy", Data("old".utf8))
        let sideData = try await remote.seed("Drive/._legacy", Data("existing AppleDouble".utf8))
        try await store.importEntries([.init(path: "legacy", size: legacyData.size, backing: locator(legacyData)),
                                      .init(path: "._legacy", size: sideData.size, backing: locator(sideData)),
                                      .init(path: "._orphan", size: 0, backing: nil)])
        try await engine.publishInitialNamespace()
        let rootID = try await store.volume().rootID
        let a = try await store.create(parentID: rootID, name: "new", kind: .file, nativeXattrs: true)
        let orphan = try await store.create(parentID: rootID, name: "orphan", kind: .file, nativeXattrs: true)
        XCTAssertNil(orphan.xattrs)
        let legacy = try required(try await store.lookup(parentID: rootID, name: "legacy"))
        do { _ = try await store.setXattr(nodeID: legacy.id, name: "com.apple.provenance", value: Data([1]), policy: "set", operationID: UUID()); XCTFail("Shadowed legacy metadata") }
        catch { XCTAssertEqual((error as NSError).code, Int(ENOTSUP)) }
        do { _ = try await store.rename(nodeID: a.id, parentID: rootID, name: "legacy", replace: true); XCTFail("Conflicting AppleDouble destination") }
        catch NamespaceFailure.collision {}
        let value = Data([0, 1, 0, 255]), op = UUID(), key = "com.apple.provenance"
        let first = try await store.setXattr(nodeID: a.id, name: key, value: value, policy: "create", operationID: op)
        let retry = try await store.setXattr(nodeID: a.id, name: key, value: value, policy: "create", operationID: op)
        XCTAssertEqual(first.id, retry.id); XCTAssertEqual(first.nodeSnapshot?.metadataGeneration, a.metadataGeneration + 1)
        do { _ = try await store.setXattr(nodeID: a.id, name: key, value: value, policy: "create", operationID: UUID()); XCTFail("Created existing key") }
        catch { XCTAssertEqual((error as NSError).code, Int(EEXIST)) }
        do { _ = try await store.setXattr(nodeID: a.id, name: key, value: Data(count: 4097), policy: "replace", operationID: UUID()); XCTFail("Oversize replacement") }
        catch { XCTAssertEqual((error as NSError).code, Int(E2BIG)) }
        let pending = try await store.node(a.id); XCTAssertEqual(pending.xattrs?[key], value)
        let other = "com.apple.finder.copy.checkpoint"
        _ = try await store.setXattr(nodeID: a.id, name: other, value: Data(), policy: "create", operationID: UUID())
        _ = try await store.setXattr(nodeID: a.id, name: other, value: Data([7]), policy: "replace", operationID: UUID())
        _ = try await store.setXattr(nodeID: a.id, name: other, value: nil, policy: "delete", operationID: UUID())
        do { _ = try await store.setXattr(nodeID: a.id, name: other, value: nil, policy: "delete", operationID: UUID()); XCTFail("Deleted absent key") }
        catch { XCTAssertEqual((error as NSError).code, Int(ENOATTR)) }
        _ = try await store.rename(nodeID: a.id, parentID: rootID, name: "moved")
        try await engine.synchronize(waitForCloud: true)
        let exporter = NamespaceExporter(store: store, content: content, remote: remote, prefix: "Drive", directory: root.appendingPathComponent("export"))
        let before = await remote.keys()
        do { _ = try await exporter.export(to: "Drive/ordinary"); XCTFail("Ordinary export lost Finder metadata") }
        catch NamespaceExportFailure.finderMetadata {
            let error = NamespaceRPCResponse.failure(.init(operation: "export"), error: NamespaceExportFailure.finderMetadata).error
            XCTAssertTrue(error?.message.contains("Finder metadata") == true)
        }
        let after = await remote.keys()
        XCTAssertEqual(after, before)
        let restored = try await NamespaceRecovery.restoreManaged(remote: remote, prefix: "Drive", directory: root.appendingPathComponent("cold"), binding: "after-loss")
        let moved = try await restored.node(a.id), old = try await restored.node(legacy.id)
        XCTAssertEqual(moved.name, "moved"); XCTAssertEqual(moved.xattrs, [key: value]); XCTAssertNil(old.xattrs)
        let restoredSide = try required(try await restored.lookup(parentID: rootID, name: "._legacy"))
        XCTAssertEqual(restoredSide.backing, locator(sideData))
        let headData = try required(await remote.bytes("Drive/.clouddrive/v1/HEAD"))
        XCTAssertEqual(try JSONDecoder().decode(ManagedHead.self, from: headData).version, 2)
    }

    func testManagedSpillReopensAndTruncatesIndexedContents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), id = UUID()
        let block = 128 * 1024, budget = Int64(256 * 1024)
        var generations = Set<UUID>()
        var expected = Data()
        var last: ContentSnapshot?
        do {
            let store = try ContentStore(directory: root, maximumBytes: budget)
            for number in 0..<40 {
                let chunk = Data(repeating: UInt8(number), count: block)
                last = try await store.prepareManagedWrite(nodeID: id, fromGeneration: Int64(number), toGeneration: Int64(number + 1),
                    logicalSize: Int64(expected.count), base: nil, previousSnapshotID: last?.id, offset: Int64(expected.count),
                    data: chunk, mutationFingerprint: nil, prefix: "Drive", remote: remote)
                generations.insert(try required(last).id)
                expected.append(chunk)
            }
            let used = await store.accounting()
            XCTAssertLessThanOrEqual(used.dirtyBytes, budget)
            XCTAssertNotNil(last?.extentRoot)
            let latest = try required(last)
            XCTAssertFalse(latest.extents.isEmpty)
            let manifest = root.appendingPathComponent("snapshots/" + latest.id.uuidString + ".json")
            XCTAssertThrowsError(try CoreFileIO.readChecked(ContentSnapshot.self, at: manifest, maximum: 16 * 1024 * 1024))
            let keys = await remote.keys()
            XCTAssertGreaterThan(keys.count, 0)
            XCTAssertLessThanOrEqual(keys.count, 20)
        }
        // Exercise a genuinely cold overlay after the disposable disk tier is
        // removed. Restart cache hits have their own verified-cache coverage.
        try FileManager.default.removeItem(at: root.appendingPathComponent("verified-cloud-cache"))
        let store = try ContentStore(directory: root, maximumBytes: budget)
        let original = try await store.snapshot(id: required(last).id)
        let readsBefore = await remote.counters().0
        await remote.configure(readDelay: true)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    var result = Data(count: 4096)
                    let holes = try await store.overlay(snapshot: original, range: 0..<4096, into: &result, remote: remote, prefix: "Drive")
                    XCTAssertTrue(holes.isEmpty)
                    return result
                }
            }
            for try await result in group { XCTAssertEqual(result, expected.prefix(4096)) }
        }
        let readsAfter = await remote.counters().0
        XCTAssertEqual(readsAfter - readsBefore, 1, "Cold packed-object reads must coalesce across overlay invocations")
        await remote.configure(readDelay: false)
        var bytes = Data(count: expected.count)
        let holes = try await store.overlay(snapshot: original, range: 0..<original.size, into: &bytes, remote: remote, prefix: "Drive")
        XCTAssertTrue(holes.isEmpty)
        XCTAssertEqual(bytes, expected)
        let boundary = 4 * 1024 * 1024
        let patch = Data(repeating: 251, count: 120)
        let rewritten = try await store.prepareManagedWrite(nodeID: id, fromGeneration: 40, toGeneration: 41, logicalSize: original.size,
            base: nil, previousSnapshotID: original.id, offset: Int64(boundary - 80), data: patch, mutationFingerprint: nil, prefix: "Drive", remote: remote)
        generations.insert(rewritten.id)
        expected.replaceSubrange((boundary - 80)..<(boundary + 40), with: patch)
        let cut = try await store.prepareTruncate(nodeID: id, fromGeneration: 41, toGeneration: 42, logicalSize: rewritten.size,
            base: nil, previousSnapshotID: rewritten.id, size: Int64(boundary + 9))
        generations.insert(cut.id)
        let extended = try await store.prepareTruncate(nodeID: id, fromGeneration: 42, toGeneration: 43, logicalSize: cut.size,
            base: nil, previousSnapshotID: cut.id, size: cut.size + 96)
        generations.insert(extended.id)
        bytes = Data(count: 205)
        let after = try await store.overlay(snapshot: extended, range: (cut.size - 109)..<(cut.size + 96), into: &bytes, remote: remote, prefix: "Drive")
        XCTAssertEqual(after, [cut.size..<extended.size])
        XCTAssertEqual(bytes.prefix(109), expected[(boundary - 100)..<(boundary + 9)])
        XCTAssertEqual(bytes.suffix(96), Data(count: 96))
        try await store.reclaim(published: generations, retaining: [])
        try await store.reclaimCloudExtents(prefix: "Drive", remote: remote)
        let remaining = await remote.keys()
        XCTAssertEqual(remaining, [])
    }

    func testManagedConcurrentFinderRangesSurvivePressureAndFailedVerification() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), block = 128 * 1024
        let (store, content, _, engine) = try setup(root, remote: remote, mode: .managed, stagingBudget: Int64(2 * block))
        let node = try await store.create(parentID: store.volume().rootID, name: "concurrent", kind: .file)
        let original = Data(repeating: 17, count: 2 * block)
        _ = try await engine.write(node: node, offset: 0, data: original)
        await remote.configure(invalidRanges: true)
        do {
            _ = try await engine.write(node: node, offset: Int64(2 * block), data: Data(repeating: 19, count: block))
            XCTFail("Failed remote verification must retain local bytes and reject the next write")
        } catch StorageFailure.integrity {}
        let retained = try await engine.read(nodeID: node.id, offset: 0, length: 2 * block)
        XCTAssertEqual(retained, original)
        await remote.configure(invalidRanges: false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 2..<10 {
                group.addTask {
                    _ = try await engine.write(node: node, offset: Int64(number * block), data: Data(repeating: UInt8(number), count: block))
                }
            }
            try await group.waitForAll()
        }
        var expected = original
        for number in 2..<10 { expected.append(Data(repeating: UInt8(number), count: block)) }
        let actual = try await engine.read(nodeID: node.id, offset: 0, length: expected.count)
        XCTAssertEqual(actual, expected)
        let usage = await content.accounting()
        XCTAssertLessThanOrEqual(usage.dirtyBytes, Int64(2 * block))
        do {
            _ = try await engine.truncate(nodeID: node.id, size: SyncEngine.managedFileLimit + 1)
            XCTFail("Unpublishable size must be refused before mutation")
        } catch StorageFailure.fileTooLarge {}
    }

    func testManagedExtentIndexDense320GiB() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let width: Int64 = 5 * 1024 * 1024
        let count = 65_537
        let extent = ContentExtent(offset: 0, length: width, fileID: UUID(), storedLength: width, checksum: String(repeating: "a", count: 64))
        let values = (0..<count).map { i in
            var entry = extent
            entry.offset = Int64(i) * width
            return entry
        }
        let index = try ManagedExtentIndex(directory)
        let root = try required(index.build(extents: values))
        let end = Int64(count) * width
        let last = try index.read(root: root, range: (end - 1)..<end)
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(try required(last.first).offset + (last.first?.length ?? 0), end)
        let trimmed = try required(index.replace(root: root, range: (end - 99)..<ManagedExtentIndex.limit, extent: nil))
        XCTAssertTrue(try index.read(root: trimmed, range: (end - 1)..<end).isEmpty)
        XCTAssertEqual(try index.read(root: root, range: (end - 1)..<end), last)
    }

    func testAcknowledgedWriteSurvivesReopenWithoutCloudPublication() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage()
        let (store, content, _, engine) = try setup(root, remote: remote)
        let volume = try await store.volume(), node = try await store.create(parentID: volume.rootID, name: "draft", kind: .file)
        let accepted = try await engine.write(nodeID: node.id, offset: 0, data: Data("saved locally".utf8))
        let snapshot = try await content.snapshot(id: required(accepted.stagedSnapshotID))
        XCTAssertEqual(snapshot.size, 13)
        let actual = try await engine.read(nodeID: node.id, offset: 0, length: 100)
        XCTAssertEqual(actual, Data("saved locally".utf8))
        let cloud = await remote.bytes("Drive/draft"); XCTAssertNil(cloud)
        try await store.close()
        let reopened = try NamespaceStore(directory: root.appendingPathComponent("namespace"), binding: "synthetic")
        let restored = try await reopened.node(node.id)
        XCTAssertEqual(restored.stagedSnapshotID, accepted.stagedSnapshotID)
        let manifest = try CoreFileIO.readChecked(ContentSnapshot.self, at: root.appendingPathComponent("content/snapshots/" + snapshot.id.uuidString + ".json"), maximum: 100_000)
        XCTAssertEqual(manifest, snapshot)
        await reopened.close()
    }
    func testPartialWriteAndTruncateNeverResurrectDiscardedBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), original = Data("abcdefghij".utf8)
        let object = try await remote.seed("Drive/file", original)
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "file", size: 10, backing: locator(object))])
        let node = try required(try await store.lookup(parentID: store.volume().rootID, name: "file"))
        _ = try await engine.write(nodeID: node.id, offset: 3, data: Data("XY".utf8))
        _ = try await engine.truncate(nodeID: node.id, size: 5)
        _ = try await engine.truncate(nodeID: node.id, size: 10)
        let bytes = try await engine.read(nodeID: node.id, offset: 0, length: 10)
        XCTAssertEqual(bytes, Data("abcXY".utf8) + Data(repeating: 0, count: 5))
        await store.close()
    }
    func testOldUploadCompletionCannotClearNewDirtyGeneration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let node = try await store.create(parentID: store.volume().rootID, name: "draft", kind: .file)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("first".utf8))
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("later".utf8))
        try await engine.processPending(limit: 2)
        let pending = try await store.node(node.id)
        XCTAssertEqual(pending.contentGeneration, 2); XCTAssertNotNil(pending.stagedSnapshotID)
        try await engine.processPending()
        let final = try await store.node(node.id), bytes = await remote.bytes("Drive/draft")
        XCTAssertNil(final.stagedSnapshotID); XCTAssertEqual(bytes, Data("later".utf8))
        await store.close()
    }
    func testRenamedDirectoryMarkerExternalReplacementIsNotDeleted() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let rootID = try await store.volume().rootID
        let folder = try await store.create(parentID: rootID, name: "Created", kind: .directory)
        _ = try await store.rename(nodeID: folder.id, parentID: rootID, name: "Moved")
        try await engine.processPending()
        _ = try await remote.seed("Drive/Moved/", Data("external replacement".utf8))
        _ = try await store.remove(nodeID: folder.id)
        do { try await engine.processPending(); XCTFail("External replacement must conflict") }
        catch StorageFailure.conflict { }
        let remaining = await remote.bytes("Drive/Moved/")
        XCTAssertEqual(remaining, Data("external replacement".utf8))
        await store.close()
    }
    func testAtomicReplacementPreservesExternallyChangedDestination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let rootID = try await store.volume().rootID
        _ = try await store.create(parentID: rootID, name: "document", kind: .file)
        let draft = try await store.create(parentID: rootID, name: "draft", kind: .file)
        _ = try await engine.write(nodeID: draft.id, offset: 0, data: Data("updated".utf8))
        try await engine.processPending()
        _ = try await store.rename(nodeID: draft.id, parentID: rootID, name: "document", replace: true)
        _ = try await remote.seed("Drive/document", Data("external bytes".utf8))
        do { try await engine.processPending(); XCTFail("An external replacement must conflict") }
        catch StorageFailure.conflict { }
        let destination = await remote.bytes("Drive/document"), source = await remote.bytes("Drive/draft")
        XCTAssertEqual(destination, Data("external bytes".utf8))
        XCTAssertEqual(source, Data("updated".utf8))
        await store.close()
    }
    func testAtomicSaveOverPendingOrPublishedFileRetainsOriginalAndPublishesReplacement() async throws {
        for destinationPublished in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
            let rootID = try await store.volume().rootID
            let target = try await store.create(parentID: rootID, name: "document", kind: .file)
            _ = try await engine.write(nodeID: target.id, offset: 0, data: Data("original".utf8))
            if destinationPublished { try await engine.processPending() }
            let before = try await store.node(target.id), lease = await engine.retain(node: before)
            let draft = try await store.create(parentID: rootID, name: "draft", kind: .file)
            _ = try await engine.write(nodeID: draft.id, offset: 0, data: Data("updated".utf8))
            let operation = try await store.rename(nodeID: draft.id, parentID: rootID, name: "document", replace: true)
            XCTAssertEqual(operation.replacedNodeID, target.id)
            let found = try await store.lookup(parentID: rootID, name: "document")
            XCTAssertEqual(found?.id, draft.id)
            try await engine.processPending()
            let bytes = await remote.bytes("Drive/document"), oldBytes = try await engine.read(node: before, offset: 0, length: 8)
            XCTAssertEqual(bytes, Data("updated".utf8))
            XCTAssertEqual(oldBytes, Data("original".utf8))
            let removed = await remote.bytes("Drive/draft"), status = try await engine.status()
            XCTAssertNil(removed); XCTAssertEqual(status.pending, 0)
            await engine.release(token: lease); await store.close()
        }
    }
    func testCreatedRenamedDirectoryMarkerCanBeRemovedUsingVerifiedAlias() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let rootID = try await store.volume().rootID
        let folder = try await store.create(parentID: rootID, name: "Created", kind: .directory)
        _ = try await store.rename(nodeID: folder.id, parentID: rootID, name: "Moved")
        _ = try await store.remove(nodeID: folder.id)
        try await engine.processPending()
        let status = try await engine.status(), keys = await remote.keys()
        XCTAssertEqual(status.pending, 0)
        XCTAssertEqual(status.attention, 0)
        XCTAssertFalse(keys.contains("Drive/Created/"))
        XCTAssertFalse(keys.contains("Drive/Moved/"))
        await store.close()
    }
    func testRenameAcknowledgesLocallyAndReadsNewPathDuringSlowCloudWork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/Album/track", Data("media".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "Album/track", size: 5, backing: locator(object))])
        let volume = try await store.volume(), album = try required(try await store.lookup(parentID: volume.rootID, name: "Album"))
        let track = try required(try await store.lookup(parentID: album.id, name: "track"))
        let start = ContinuousClock.now
        _ = try await store.rename(nodeID: album.id, parentID: volume.rootID, name: "Moved")
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let newPath = try await store.resolvedPath(track.id); XCTAssertEqual(newPath, "Moved/track")
        await remote.configure(listDelay: true)
        let job = Task { try await engine.processPending() }
        let data = try await engine.read(nodeID: track.id, offset: 0, length: 5)
        XCTAssertEqual(data, Data("media".utf8))
        try await job.value
        let old = await remote.bytes("Drive/Album/track"), moved = await remote.bytes("Drive/Moved/track")
        XCTAssertNil(old); XCTAssertEqual(moved, Data("media".utf8))
        let oldHandleRead = try await engine.read(node: track, offset: 0, length: 5)
        XCTAssertEqual(oldHandleRead, Data("media".utf8))
        await store.close()
    }
    func testUnqualifiedDeletePreservesBothCopiesAndRecoveryContinues() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/old", Data("bytes".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "old", size: 5, backing: locator(object))])
        let volume = try await store.volume(), node = try required(try await store.lookup(parentID: volume.rootID, name: "old"))
        _ = try await store.rename(nodeID: node.id, parentID: volume.rootID, name: "new")
        await remote.configure(failDelete: true)
        do { try await engine.processPending(); XCTFail("unsupported delete must retain recovery") } catch StorageFailure.unsupported {}
        let old = await remote.bytes("Drive/old"), new = await remote.bytes("Drive/new")
        XCTAssertEqual(old, new); XCTAssertEqual(new, Data("bytes".utf8))
        let status = try await engine.status(); XCTAssertEqual(status.attention, 1)
        let read = try await engine.read(node: node, offset: 0, length: 5); XCTAssertEqual(read, new)
        await remote.configure(failDelete: false)
        try await engine.resume()
        let source = await remote.bytes("Drive/old"); XCTAssertNil(source)
        await store.close()
    }
    func testSemanticallyIdenticalLegacyReceiptEncodingCanResume() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/old", Data("bytes".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "old", size: 5, backing: locator(object))])
        let volume = try await store.volume(), node = try required(try await store.lookup(parentID: volume.rootID, name: "old"))
        let operation = try await store.rename(nodeID: node.id, parentID: volume.rootID, name: "new")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await store.recordReceipt(operationID: operation.id, stepID: "delete-intent-" + CoreFileIO.hash(Data(object.key.utf8)), validator: encoder.encode(object).base64EncodedString())
        try await engine.processPending()
        let source = await remote.bytes("Drive/old"), destination = await remote.bytes("Drive/new")
        XCTAssertNil(source); XCTAssertEqual(destination, Data("bytes".utf8))
        await store.close()
    }
    func testLostDeleteResponseReconcilesFromDurableIntent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/old", Data("bytes".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "old", size: 5, backing: locator(object))])
        let volume = try await store.volume(), node = try required(try await store.lookup(parentID: volume.rootID, name: "old"))
        _ = try await store.rename(nodeID: node.id, parentID: volume.rootID, name: "new")
        await remote.configure(loseDelete: true)
        do { try await engine.processPending(); XCTFail("lost response must be retained") } catch StorageFailure.unknownOutcome {}
        try await engine.resume()
        let status = try await engine.status(), moved = await remote.bytes("Drive/new")
        XCTAssertEqual(status.pending, 0); XCTAssertEqual(moved, Data("bytes".utf8))
        await store.close()
    }
    func testChangedSourceNeverAdmitsDeletion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/old", Data("bytes".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "old", size: 5, backing: locator(object))])
        let volume = try await store.volume(), node = try required(try await store.lookup(parentID: volume.rootID, name: "old"))
        _ = try await store.rename(nodeID: node.id, parentID: volume.rootID, name: "new")
        await remote.configure(mutateAfterCopy: true)
        do { try await engine.processPending(); XCTFail("external mutation must stop destructive work") } catch StorageFailure.conflict {}
        let counters = await remote.counters(), source = await remote.bytes("Drive/old")
        XCTAssertEqual(counters.2, 0); XCTAssertEqual(source, Data("external changed".utf8))
        await store.close()
    }
    func testOfflineAvailabilityRequiresCurrentIntactCachedBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/file", Data(repeating: 7, count: 4096))
        let cache = try RangeCache(directory: root.appendingPathComponent("cache"), maximumBytes: 8192, chunkSize: 4096)
        let node = NamespaceNode(id: UUID(), inode: 2, parentID: nil, name: "file", kind: .file,
                                 size: 4096, backing: locator(object))
        let key = "availability:" + node.id.uuidString
        var states = try await cache.availability(nodes: [node]); XCTAssertEqual(states[key], "remoteOnly")
        try await cache.requestPin(node: node)
        states = try await cache.availability(nodes: [node]); XCTAssertEqual(states[key], "downloading")
        _ = try await cache.read(nodeID: node.id, generation: 0, locator: locator(object), range: 0..<4096, remote: remote)
        try await cache.updatePin(nodeID: node.id, completedBytes: 4096, state: "complete")
        states = try await cache.availability(nodes: [node]); XCTAssertEqual(states[key], "availableOffline")
        states = try await cache.availability(nodes: [node], maximumVerificationBytes: 0); XCTAssertEqual(states[key], "unknown")
        let changed = NamespaceNode(id: node.id, inode: 2, parentID: nil, name: "file", kind: .file,
                                    size: 4096, contentGeneration: 1, backing: locator(object))
        states = try await cache.availability(nodes: [changed]); XCTAssertEqual(states[key], "unknown")
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: nil)
        let chunk = try XCTUnwrap(files.first { $0.lastPathComponent.count == 64 })
        try Data(repeating: 8, count: 4096).write(to: chunk)
        states = try await cache.availability(nodes: [node]); XCTAssertEqual(states[key], "attention")
        try FileManager.default.removeItem(at: chunk)
        states = try await cache.availability(nodes: [node]); XCTAssertEqual(states[key], "attention")
    }
    func testRangeValidationCoalescingAndPinsKeepCacheBounded() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/file", Data(repeating: 7, count: 8192))
        let cache = try RangeCache(directory: root.appendingPathComponent("cache"), maximumBytes: 4096, chunkSize: 4096), id = UUID()
        await remote.configure(invalidRanges: true)
        do { _ = try await cache.read(nodeID: id, generation: 0, locator: locator(object), range: 0..<4096, remote: remote); XCTFail("bad Content-Range accepted") } catch StorageFailure.invalidResponse {}
        let empty = await cache.accounting(); XCTAssertEqual(empty.cleanBytes, 0)
        await remote.configure(invalidRanges: false, readDelay: true)
        async let first = cache.read(nodeID: id, generation: 0, locator: locator(object), range: 0..<4096, remote: remote)
        async let second = cache.read(nodeID: id, generation: 0, locator: locator(object), range: 0..<4096, remote: remote)
        let (a,b) = try await (first,second); XCTAssertEqual(a,b)
        let counters = await remote.counters(); XCTAssertEqual(counters.0, 2) // one bad request + one shared fetch
        try await cache.pin(nodeID: id)
        do { _ = try await cache.read(nodeID: id, generation: 0, locator: locator(object), range: 4096..<8192, remote: remote, requireResident: true); XCTFail("pin must not evict another pinned chunk") } catch StorageFailure.localStorageFull {}
        let accounting = await cache.accounting(); XCTAssertEqual(accounting.cleanBytes, 4096); XCTAssertEqual(accounting.pinnedBytes, 4096)
        let streamed = try await cache.read(nodeID: id, generation: 0, locator: locator(object), range: 4096..<8192, remote: remote)
        XCTAssertEqual(streamed, Data(repeating: 7, count: 4096))
    }
    func testLowStorageRejectsWriteWithoutChangingNamespaceGeneration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, stagingBudget: 4)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file)
        do { _ = try await engine.write(nodeID: node.id, offset: 0, data: Data(repeating: 1, count: 5)); XCTFail("over budget write accepted") } catch StorageFailure.localStorageFull {}
        let unchanged = try await store.node(node.id)
        XCTAssertEqual(unchanged.contentGeneration, 0); XCTAssertEqual(unchanged.size, 0)
        await store.close()
    }
    func testManagedLostHeadReplyAndMetadataMoveUseNoContentCopy() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume(), node = try await store.create(parentID: volume.rootID, name: "first", kind: .file)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("content".utf8))
        await remote.configure(loseHeadPut: true)
        try await engine.synchronize(waitForCloud: true)
        let before = await remote.counters()
        _ = try await store.rename(nodeID: node.id, parentID: volume.rootID, name: "after")
        try await engine.synchronize(waitForCloud: true)
        let after = await remote.counters(); XCTAssertEqual(before.1, after.1)
        let publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        let record = try required(try await publisher.lookup(parentID: volume.rootID, name: "after"))
        XCTAssertEqual(record.id, node.id)
        let records = try await publisher.exportRecords(); XCTAssertTrue(records.contains { $0.id == volume.rootID })
        XCTAssertEqual(record.backing?.size, 7)
        await store.close()
    }
    func testManagedSeedPublishesAllImportedNodesOnlyAtCompleteRoot() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        try await store.importEntries((0..<4200).map { .init(path: "Folder/file-\($0)", size: 0) })
        try await engine.publishInitialNamespace()
        let volume = try await store.volume(), publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        let records = try await publisher.exportRecords()
        XCTAssertEqual(records.count, 4202)
        let lookup = try await publisher.lookup(parentID: records.first { $0.name == "Folder" }!.id, name: "file-4199")
        XCTAssertNotNil(lookup)
        await store.close()
    }
    func testOpenUnlinkedWriteIsDurableLocalOnlyAndDoesNotResurrectPath() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("before".utf8))
        try await engine.synchronize(waitForCloud: true)
        let opened = try await store.node(node.id), token = await engine.retain(node: opened)
        _ = try await store.remove(nodeID: node.id)
        let retained = try await engine.write(node: opened, offset: 0, data: Data("after!".utf8))
        let bytes = try await engine.read(node: retained, offset: 0, length: 6)
        XCTAssertEqual(bytes, Data("after!".utf8))
        try await engine.synchronize(waitForCloud: true)
        let volume = try await store.volume(), publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        let absent = try await publisher.node(id: node.id); XCTAssertNil(absent)
        await engine.release(token: token); await store.close()
    }
    func testUnlinkedLocalGenerationsStayDirtyUntilLastHandleClosesThenDiscardWithoutPublication() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote, mode: .managed)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("before".utf8))
        try await engine.synchronize(waitForCloud: true)
        let opened = try await store.node(node.id)
        let first = await engine.retain(node: opened), second = await engine.retain(node: opened)
        _ = try await store.remove(nodeID: node.id)
        let written = try await engine.write(node: opened, offset: 0, data: Data("after!".utf8))
        let snapshot = try required(written.stagedSnapshotID)
        await engine.release(token: first)
        let whilePending = await content.accounting(); XCTAssertGreaterThan(whilePending.dirtyBytes, 0)
        try await engine.synchronize(waitForCloud: true)
        let retained = try await content.snapshot(id: snapshot); XCTAssertEqual(retained.nodeID, node.id)
        let inventory = try await store.snapshotInventory()
        XCTAssertTrue(inventory.discarded.contains(snapshot)); XCTAssertFalse(inventory.published.contains(snapshot))
        let unpublished = try await store.publishedLocator(nodeID: node.id, generation: written.contentGeneration); XCTAssertNil(unpublished)
        let bytes = try await engine.read(node: written, offset: 0, length: 6); XCTAssertEqual(bytes, Data("after!".utf8))
        await engine.release(token: second)
        let cleaned = await content.accounting(); XCTAssertEqual(cleaned.dirtyBytes, 0)
        do { _ = try await content.snapshot(id: snapshot); XCTFail("unlinked snapshot remained after final close") } catch StorageFailure.notFound {}
        let proof = try CoreFileIO.readChecked(Set<UUID>.self, at: root.appendingPathComponent("content/discarded-snapshots.json"), maximum: 100_000)
        XCTAssertTrue(proof.contains(snapshot))
        await store.close()
    }

    func testRecursiveRemoveProvesDescendantLocalDiscardOnlyAfterCloudCompletion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote, mode: .managed)
        let folder = try await store.create(parentID: store.volume().rootID, name: "folder", kind: .directory)
        let node = try await store.create(parentID: folder.id, name: "file", kind: .file)
        try await engine.synchronize(waitForCloud: true)
        let token = await engine.retain(node: node)
        _ = try await store.remove(nodeID: folder.id, recursive: true)
        let written = try await engine.write(node: node, offset: 0, data: Data("orphan".utf8))
        let snapshot = try required(written.stagedSnapshotID)
        await engine.release(token: token)
        let pending = try await store.snapshotInventory(); XCTAssertFalse(pending.discarded.contains(snapshot))
        _ = try await content.snapshot(id: snapshot)
        try await engine.synchronize(waitForCloud: true)
        let cleaned = await content.accounting(); XCTAssertEqual(cleaned.dirtyBytes, 0)
        do { _ = try await content.snapshot(id: snapshot); XCTFail("removed descendant remained") } catch StorageFailure.notFound {}
        await store.close()
    }

    func testRapidFolderMovesNewChildAndMovedOutChildPreserveAcceptedOrder() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/A/old", Data("original".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "A/old", size: 8, backing: locator(object))])
        let volume = try await store.volume(), folder = try required(try await store.lookup(parentID: volume.rootID, name: "A"))
        let old = try required(try await store.lookup(parentID: folder.id, name: "old"))
        _ = try await store.rename(nodeID: folder.id, parentID: volume.rootID, name: "B")
        let new = try await store.create(parentID: folder.id, name: "new", kind: .file)
        _ = try await store.rename(nodeID: old.id, parentID: volume.rootID, name: "moved-out")
        _ = try await store.rename(nodeID: folder.id, parentID: volume.rootID, name: "C")
        try await engine.synchronize(waitForCloud: true)
        let oldBytes = try await engine.read(node: old, offset: 0, length: 8)
        let finalOld = await remote.bytes("Drive/moved-out"), finalNew = await remote.bytes("Drive/C/new")
        XCTAssertEqual(oldBytes, Data("original".utf8)); XCTAssertEqual(finalOld, oldBytes); XCTAssertEqual(finalNew, Data())
        let path = try await store.resolvedPath(new.id); XCTAssertEqual(path, "C/new")
        let keys = await remote.keys(); XCTAssertFalse(keys.contains { $0.hasPrefix("Drive/A/") || $0.hasPrefix("Drive/B/") })
        await store.close()
    }
    func testReplacementRetainsOldOpenHandleAndNewNodeIdentity() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), first = try await remote.seed("Drive/first", Data("first".utf8)), second = try await remote.seed("Drive/second", Data("other".utf8))
        let (store, content, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "first", size: 5, backing: locator(first)), .init(path: "second", size: 5, backing: locator(second))])
        let volume = try await store.volume(), a = try required(try await store.lookup(parentID: volume.rootID, name: "first")), b = try required(try await store.lookup(parentID: volume.rootID, name: "second"))
        let lease = await engine.retain(node: b)
        _ = try await store.rename(nodeID: a.id, parentID: volume.rootID, name: "second", replace: true)
        try await engine.synchronize(waitForCloud: true)
        let old = try await engine.read(node: b, offset: 0, length: 5), new = try await engine.read(nodeID: a.id, offset: 0, length: 5)
        XCTAssertEqual(old, Data("other".utf8)); XCTAssertEqual(new, Data("first".utf8))
        let unlinked = try await engine.write(node: b, offset: 0, data: Data("local".utf8))
        try await engine.reclaimPublishedLocalData()
        let snapshot = try required(unlinked.stagedSnapshotID)
        _ = try await content.snapshot(id: snapshot)
        let inventory = try await store.snapshotInventory(); XCTAssertTrue(inventory.discarded.contains(snapshot))
        await engine.release(token: lease)
        let cleaned = await content.accounting(); XCTAssertEqual(cleaned.dirtyBytes, 0)
        let actual = await remote.bytes("Drive/second"); XCTAssertEqual(actual, Data("first".utf8))
        await store.close()
    }
    func testKnownCopyChecksumCannotDisappearBeforeDeleteBarrier() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/old", Data("bytes".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "old", size: 5, backing: locator(object))])
        let volume = try await store.volume(), node = try required(try await store.lookup(parentID: volume.rootID, name: "old"))
        _ = try await store.rename(nodeID: node.id, parentID: volume.rootID, name: "new")
        await remote.configure(dropCopyChecksum: true)
        do { try await engine.processPending(); XCTFail("known checksum proof disappeared") } catch StorageFailure.integrity {}
        let counters = await remote.counters(); XCTAssertEqual(counters.2, 0)
        await store.close()
    }
    func testDirectSourceKeepsOriginalAndDoesNotSpoolPayload() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("original.bin").resolvingSymlinksInPath()
        let bytes = Data(repeating: 17, count: 32_000); try bytes.write(to: sourceURL)
        let source = try ResidentSourceIdentity.capture(url: sourceURL)
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote)
        let volume = try await store.volume(), node = try await engine.createFromSource(parentID: volume.rootID, name: "uploaded", source: source)
        let accounting = await content.accounting(); XCTAssertEqual(accounting.dirtyBytes, 0)
        let read = try await engine.read(nodeID: node.id, offset: 123, length: 100)
        XCTAssertEqual(read, bytes.subdata(in: 123..<223))
        try await engine.synchronize(waitForCloud: true)
        let uploaded = await remote.bytes("Drive/uploaded"); XCTAssertEqual(uploaded, bytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        await store.close()
    }
    func testChangedDirectSourceFailsWithoutUploadingTruncatedBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("original.bin").resolvingSymlinksInPath(); try Data("before".utf8).write(to: sourceURL)
        let source = try ResidentSourceIdentity.capture(url: sourceURL)
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let node = try await engine.createFromSource(parentID: store.volume().rootID, name: "uploaded", source: source)
        try Data("edited".utf8).write(to: sourceURL)
        do { _ = try await engine.read(nodeID: node.id, offset: 0, length: 6); XCTFail("changed source read accepted") } catch StorageFailure.integrity {}
        do { try await engine.processPending(); XCTFail("changed source upload accepted") } catch StorageFailure.integrity {}
        let uploaded = await remote.bytes("Drive/uploaded"); XCTAssertNil(uploaded)
        await store.close()
    }

    func testMissingExpectedInventoryNeverCompletesMoveAsEmptyFolder() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/A/file", Data("known".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "A/file", size: 5, backing: locator(object))])
        let volume = try await store.volume(), node = try required(try await store.lookup(parentID: volume.rootID, name: "A"))
        _ = try await store.rename(nodeID: node.id, parentID: volume.rootID, name: "B")
        try await remote.delete(key: object.key, validator: object.validator)
        do { try await engine.processPending(); XCTFail("missing expected source was silently omitted") } catch StorageFailure.conflict {}
        let status = try await engine.status(); XCTAssertEqual(status.attention, 1)
        let counters = await remote.counters(); XCTAssertEqual(counters.1, 0); XCTAssertEqual(counters.2, 1)
        await store.close()
    }
    func testMetadataLostReplyReconcilesWithoutLosingOpenFileBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/file", Data("bytes".utf8))
        let (store, _, _, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "file", size: 5, backing: locator(object))])
        let volume = try await store.volume(), node = try required(try await store.lookup(parentID: volume.rootID, name: "file"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.updateMetadata(nodeID: node.id, modifiedAt: date)
        await remote.configure(loseMetadataReply: true)
        do { try await engine.processPending(); XCTFail("unknown metadata outcome must remain recoverable") } catch StorageFailure.unknownOutcome {}
        try await engine.resume()
        let actual = await remote.head(key: object.key); XCTAssertEqual(actual?.modifiedAt, date)
        let counters = await remote.counters(); XCTAssertEqual(counters.0, 0)
        let oldHandleBytes = try await engine.read(node: node, offset: 0, length: 5)
        XCTAssertEqual(oldHandleBytes, Data("bytes".utf8))
        await store.close()
    }
    func testReplacedContentDirectoryCannotAcceptNewBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file)
        try FileManager.default.moveItem(at: root.appendingPathComponent("content"), to: root.appendingPathComponent("retained-content"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("content"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do { _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("bytes".utf8)); XCTFail("replaced directory admitted bytes") } catch StorageFailure.integrity {}
        let unchanged = try await store.node(node.id); XCTAssertEqual(unchanged.contentGeneration, 0)
        await store.close()
    }
    func testCheckedManifestRejectsValidJSONMetadataCorruption() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("checkpoint.json")
        try CoreFileIO.atomicChecked(["accepted": 17], at: url)
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        envelope["checksum"] = String(repeating: "0", count: 64)
        try CoreFileIO.atomic(JSONSerialization.data(withJSONObject: envelope), at: url)
        do { let _: [String:Int] = try CoreFileIO.readChecked([String:Int].self, at: url, maximum: 1024); XCTFail("corrupt metadata was accepted") } catch StorageFailure.integrity {}
    }
    func testRangeCacheEnforcesSingleOwner() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try RangeCache(directory: root.appendingPathComponent("cache"))
        do { _ = try RangeCache(directory: root.appendingPathComponent("cache")); XCTFail("second cache writer admitted") } catch StorageFailure.busy {}
        let accounting = await first.accounting(); XCTAssertEqual(accounting.cleanBytes, 0)
    }
    func testRecursiveManagedDeleteRemainsRecoverableAsOneTombstone() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        try await store.importEntries([.init(path: "Folder/child", size: 0)])
        try await engine.publishInitialNamespace()
        let volume = try await store.volume(), folder = try required(try await store.lookup(parentID: volume.rootID, name: "Folder"))
        _ = try await store.remove(nodeID: folder.id, recursive: true)
        try await engine.synchronize(waitForCloud: true)
        let publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        let records = try await publisher.exportRecords(); XCTAssertEqual(records.count, 1)
        let absent = try await publisher.node(id: folder.id); XCTAssertNil(absent)
        await store.close()
    }

    private func waitPin(_ cache: RangeCache, id: UUID, state: String) async throws -> PinProgress {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if let request = try await cache.pinRequest(nodeID: id), request.state == state { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Pin did not reach expected state \(state)"); throw StorageFailure.busy
    }
    func testVerifiedStagingGCSeparatesDirtyAndRetainedCleanHandleData() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote, mode: .managed)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file)
        let written = try await engine.write(nodeID: node.id, offset: 0, data: Data("protected".utf8)), lease = await engine.retain(node: written)
        try await engine.synchronize(waitForCloud: true)
        let held = await content.accounting(); XCTAssertEqual(held.dirtyBytes, 0); XCTAssertGreaterThan(held.retainedCleanBytes, 0)
        let bytes = try await engine.read(node: written, offset: 0, length: 9); XCTAssertEqual(bytes, Data("protected".utf8))
        await engine.release(token: lease)
        let released = await content.accounting(); XCTAssertEqual(released.dirtyBytes, 0); XCTAssertEqual(released.retainedCleanBytes, 0); XCTAssertEqual(released.snapshotCount, 0)
        // A captured generation that has a cloud receipt can still read after its
        // verified local snapshot was reclaimed.
        let cold = try await engine.read(node: written, offset: 0, length: 9); XCTAssertEqual(cold, bytes)
        await store.close()
    }
    func testSharedPublishedExtentRemainsAvailableToNewDirtyGeneration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote, mode: .managed)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("abcdefgh".utf8))
        let newer = try await engine.write(nodeID: node.id, offset: 3, data: Data("XY".utf8))
        try await engine.processPending(limit: 2)
        let accounting = await content.accounting(); XCTAssertGreaterThan(accounting.dirtyBytes, 0); XCTAssertGreaterThan(accounting.retainedCleanBytes, 0)
        let current = try await engine.read(node: newer, offset: 0, length: 8)
        XCTAssertEqual(current, Data("abcXYfgh".utf8))
        try await engine.synchronize(waitForCloud: true)
        let done = await content.accounting(); XCTAssertEqual(done.dirtyBytes, 0); XCTAssertEqual(done.retainedCleanBytes, 0)
        await store.close()
    }
    func testBoundedSnapshotSupportsMoreThan4096Extents() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("content")
        try CoreFileIO.privateDirectory(directory); try CoreFileIO.privateDirectory(directory.appendingPathComponent("extents")); try CoreFileIO.privateDirectory(directory.appendingPathComponent("snapshots"))
        let id = UUID(), fileID = UUID(), data = Data([17]), checksum = CoreFileIO.hash(data)
        try CoreFileIO.atomic(data, at: directory.appendingPathComponent("extents/" + fileID.uuidString))
        let extents = (0..<4097).map { ContentExtent(offset: Int64($0) * 1_048_576, length: 1, fileID: fileID, storedLength: 1, checksum: checksum) }
        let snapshot = ContentSnapshot(id: id, nodeID: UUID(), generation: 1, size: 4096 * 1_048_576 + 1, base: nil, baseReadableSize: 0, extents: extents)
        try CoreFileIO.atomicChecked(snapshot, at: directory.appendingPathComponent("snapshots/" + id.uuidString + ".json"))
        let content = try ContentStore(directory: directory, maximumBytes: 20_000_000)
        let loaded = try await content.snapshot(id: id); XCTAssertEqual(loaded.extents.count, 4097)
        var last = Data(count: 1)
        let holes = try await content.overlay(snapshot: loaded, range: loaded.size - 1..<loaded.size, into: &last)
        XCTAssertTrue(holes.isEmpty); XCTAssertEqual(last, data)
    }
    func testRecursivePinIncludesFutureChildrenAndReportsResidentProgress() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/Folder/one", Data("one".utf8))
        let (store, _, cache, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "Folder/one", size: 3, backing: locator(object))])
        let volume = try await store.volume(), folder = try required(try await store.lookup(parentID: volume.rootID, name: "Folder"))
        let one = try required(try await store.lookup(parentID: folder.id, name: "one"))
        try await engine.pin(nodeID: folder.id, recursive: true)
        let first = try await waitPin(cache, id: one.id, state: "complete"); XCTAssertEqual(first.completedBytes, 3)
        _ = try await waitPin(cache, id: folder.id, state: "complete")
        let child = try await store.create(parentID: folder.id, name: "future", kind: .file)
        _ = try await engine.write(nodeID: child.id, offset: 0, data: Data("new".utf8))
        try await engine.synchronize(waitForCloud: true)
        let future = try await waitPin(cache, id: child.id, state: "complete"); XCTAssertEqual(future.completedBytes, 3)
        let status = try await engine.status(); XCTAssertGreaterThanOrEqual(status.requestedPins, 3); XCTAssertEqual(status.pinAttention, 0)
        let cacheDirectory = await cache.directory
        let journal = try PinJournal(directory: cacheDirectory), saved = try journal.all()
        XCTAssertTrue(saved.contains { $0.nodeID == folder.id && $0.recursive })
        XCTAssertTrue(saved.contains { $0.nodeID == child.id && $0.state == "complete" })
        try await engine.unpin(nodeID: folder.id, recursive: true)
        let remaining = try await engine.pinProgress(); XCTAssertTrue(remaining.isEmpty)
        await store.close()
    }
    func testManagedPinContinuesAfterNetworkReturnsWithoutRepinning() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/note", Data("notes".utf8))
        let (store, _, cache, engine) = try setup(root, remote: remote, mode: .managed)
        try await store.importEntries([.init(path: "note", size: 5, backing: locator(object))])
        let node = try required(try await store.lookup(parentID: store.volume().rootID, name: "note"))
        await remote.setOffline(true)
        try await engine.pin(nodeID: node.id, recursive: false)
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while try await cache.pinRequest(nodeID: node.id)?.error != "offline", ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = try await engine.status()
        XCTAssertEqual(waiting.phase, "waitingForNetwork")
        await remote.setOffline(false)
        try await Task.sleep(for: .milliseconds(4100))
        try await engine.processPending(waitForQuiet: true)
        let pin = try await waitPin(cache, id: node.id, state: "complete")
        XCTAssertEqual(pin.completedBytes, 5)
        await store.close()
    }

    func testPinPressureRetainsPartialProgressAndDoesNotClaimSuccess() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), object = try await remote.seed("Drive/large", Data(repeating: 3, count: 12_288))
        let (store, _, cache, engine) = try setup(root, remote: remote)
        try await store.importEntries([.init(path: "large", size: object.size, backing: locator(object))])
        let node = try required(try await store.lookup(parentID: store.volume().rootID, name: "large"))
        try await engine.pin(nodeID: node.id)
        let failed = try await waitPin(cache, id: node.id, state: "attention")
        XCTAssertEqual(failed.completedBytes, 8192); XCTAssertEqual(failed.size, 12_288)
        let status = try await engine.status(); XCTAssertEqual(status.pinAttention, 1); XCTAssertEqual(status.completedPins, 0)
        let accounting = await cache.accounting(); XCTAssertEqual(accounting.cleanBytes, 8192)
        try await engine.unpin(nodeID: node.id); await store.close()
    }

    func testDurableWriteReplayAfterManifestGCDoesNotOverwriteInterveningWrite() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, cache, engine) = try setup(root, remote: remote, mode: .managed)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file), requestID = UUID()
        let first = try await engine.write(nodeID: node.id, offset: 0, data: Data("first".utf8), operationID: requestID)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("later".utf8))
        try await engine.synchronize(waitForCloud: true)
        let accounting = await content.accounting(); XCTAssertEqual(accounting.snapshotCount, 0)
        await store.close()
        let reopened = try NamespaceStore(directory: root.appendingPathComponent("namespace"), binding: "synthetic", mode: .managed)
        let restored = SyncEngine(store: reopened, content: content, cache: cache, remote: remote, prefix: "Drive", mode: .managed)
        let replay = try await restored.write(nodeID: node.id, offset: 0, data: Data("first".utf8), operationID: requestID)
        XCTAssertEqual(replay.contentGeneration, first.contentGeneration)
        let current = try await reopened.node(node.id), bytes = try await restored.read(nodeID: node.id, offset: 0, length: 5)
        XCTAssertEqual(current.contentGeneration, 2); XCTAssertEqual(bytes, Data("later".utf8))
        do { _ = try await restored.write(nodeID: node.id, offset: 0, data: Data("other".utf8), operationID: requestID); XCTFail("conflicting RPC ID payload accepted") } catch NamespaceFailure.invalidTransition {}
        let after = try await reopened.node(node.id); XCTAssertEqual(after.contentGeneration, 2)
        await reopened.close()
    }
    func testTruncateReplayDoesNotTruncateANewerWrite() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("abcdef".utf8))
        let requestID = UUID(), first = try await engine.truncate(nodeID: node.id, size: 2, operationID: requestID)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("latest".utf8))
        let replay = try await engine.truncate(nodeID: node.id, size: 2, operationID: requestID)
        XCTAssertEqual(replay.contentGeneration, first.contentGeneration)
        let current = try await engine.read(nodeID: node.id, offset: 0, length: 6); XCTAssertEqual(current, Data("latest".utf8))
        do { _ = try await engine.truncate(nodeID: node.id, size: 3, operationID: requestID); XCTFail("conflicting truncate replay accepted") } catch NamespaceFailure.invalidTransition {}
        await store.close()
    }
    func testMultipartReaderComposesLargeSparseBaseEditsWithBoundedReads() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), original = Data(repeating: 19, count: 20 * 1024 * 1024)
        let object = try await remote.seed("Drive/large", original)
        let store = try NamespaceStore(directory: root.appendingPathComponent("namespace"), binding: "synthetic")
        let content = try ContentStore(directory: root.appendingPathComponent("content"), maximumBytes: 1_000_000)
        let cache = try RangeCache(directory: root.appendingPathComponent("cache"), maximumBytes: 4 * 1024 * 1024, chunkSize: 1024 * 1024)
        let engine = SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: "Drive")
        try await store.importEntries([.init(path: "large", size: object.size, backing: locator(object))])
        let node = try required(try await store.lookup(parentID: store.volume().rootID, name: "large"))
        _ = try await engine.write(nodeID: node.id, offset: 12345, data: Data([1,2,3]))
        try await engine.synchronize(waitForCloud: true)
        var expected = original; expected.replaceSubrange(12345..<12348, with: [1,2,3])
        let uploaded = await remote.bytes("Drive/large"); XCTAssertEqual(uploaded, expected)
        let accounting = await cache.accounting(); XCTAssertLessThanOrEqual(accounting.cleanBytes, 4 * 1024 * 1024)
        await store.close()
    }

    func testZeroLengthWriteReplayCannotBeReusedForAnActualWrite() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let node = try await store.create(parentID: store.volume().rootID, name: "file", kind: .file), id = UUID()
        let first = try await engine.write(nodeID: node.id, offset: 100, data: Data(), operationID: id)
        XCTAssertEqual(first.contentGeneration, 0); XCTAssertEqual(first.size, 0)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("later".utf8))
        let replay = try await engine.write(nodeID: node.id, offset: 100, data: Data(), operationID: id)
        XCTAssertEqual(replay.contentGeneration, 0)
        do { _ = try await engine.write(nodeID: node.id, offset: 100, data: Data("bad".utf8), operationID: id); XCTFail("zero write ID was reused to overwrite content") } catch NamespaceFailure.invalidTransition {}
        let current = try await engine.read(nodeID: node.id, offset: 0, length: 5); XCTAssertEqual(current, Data("later".utf8))
        await store.close()
    }

    func testMalformedManagedTrieWithDuplicateNodeIdentityFailsWithoutTrap() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, _) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume(), node = try await store.node(volume.rootID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let first = ManagedNodeRecord(node: node)
        var duplicate = first; duplicate.modifiedAt = Date(timeIntervalSince1970: 1)
        func page(_ record: ManagedNodeRecord) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "depth": 1, "records": [node.id.uuidString: encoder.encode(record).base64EncodedString()], "children": [String:String]()], options: [.sortedKeys])
        }
        let a = try page(first), b = try page(duplicate), aHash = CoreFileIO.hash(a), bHash = CoreFileIO.hash(b)
        _ = try await remote.seed("Drive/.clouddrive/v1/metadata/" + aHash, a)
        _ = try await remote.seed("Drive/.clouddrive/v1/metadata/" + bHash, b)
        let correct = String(CoreFileIO.hash(Data(node.id.uuidString.utf8)).prefix(1)), wrong = correct == "0" ? "1" : "0"
        let rootPage = try JSONSerialization.data(withJSONObject: ["version": 1, "depth": 0, "records": [String:String](), "children": [correct:aHash, wrong:bHash]], options: [.sortedKeys])
        let rootHash = CoreFileIO.hash(rootPage)
        _ = try await remote.seed("Drive/.clouddrive/v1/metadata/" + rootHash, rootPage)
        let commit = ManagedCommit(volumeID: volume.id, revision: 0, parentCommit: nil, operationIDs: [], nodeRoot: rootHash, directoryRoot: nil)
        let commitData = try encoder.encode(commit), commitHash = CoreFileIO.hash(commitData)
        _ = try await remote.seed("Drive/.clouddrive/v1/commits/" + commitHash, commitData)
        _ = try await remote.seed("Drive/.clouddrive/v1/HEAD", encoder.encode(ManagedHead(volumeID: volume.id, commitID: commitHash)))
        let publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        do { _ = try await publisher.exportRecords(); XCTFail("malformed duplicate identity graph was accepted") } catch StorageFailure.integrity {}
        await store.close()
    }

    func testPauseFinishesCurrentAcceptedObjectAndPreservesRemainingQueue() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote)
        let volume = try await store.volume(), a = try await store.create(parentID: volume.rootID, name: "a", kind: .file)
        _ = try await engine.write(nodeID: a.id, offset: 0, data: Data("first".utf8))
        let b = try await store.create(parentID: volume.rootID, name: "b", kind: .file)
        _ = try await engine.write(nodeID: b.id, offset: 0, data: Data("second".utf8))
        await remote.configure(uploadDelay: true)
        let job = Task { try await engine.processPending(limit: 4) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await remote.startedUploads() == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await engine.requestPause()
        try await job.value
        let status = try await engine.status(), queue = try await store.operations(limit: 10), first = await remote.bytes("Drive/a"), second = await remote.bytes("Drive/b")
        XCTAssertEqual(status.phase, "paused"); XCTAssertEqual(queue.count, 2); XCTAssertTrue(queue.allSatisfy { $0.state == .pending })
        XCTAssertEqual(first, Data("first".utf8)); XCTAssertNil(second)
        do { try await engine.synchronize(waitForCloud: true); XCTFail("paused cloud fence must not spin or claim success") } catch StorageFailure.busy {}
        try await engine.resume()
        let completed = await remote.bytes("Drive/b"); XCTAssertEqual(completed, Data("second".utf8))
        await store.close()
    }

    func testOfflineManagedMutationRecoversWithoutResumeIncludingOldAttentionRecord() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        _ = try await store.create(parentID: volume.rootID, name: "offline.txt", kind: .file)
        await remote.setOffline(true)
        do { try await engine.processPending(); XCTFail("unexpected publication while offline") } catch StorageFailure.offline {}
        let waiting = try await engine.status()
        XCTAssertEqual(waiting.phase, "waitingForNetwork")
        XCTAssertEqual(waiting.attention, 0)
        let queue = try await store.operations(limit: 1)
        let op = try XCTUnwrap(queue.first)
        XCTAssertEqual(op.state, .pending)
        try await engine.processPending(waitForQuiet: true)
        let unchanged = try await store.operation(op.id)
        XCTAssertEqual(unchanged?.attemptCount, op.attemptCount)
        // An owner from before automatic retries may have persisted the same failure as attention.
        try await store.setOperationState(op.id, state: .attention, errorCode: "offline")
        await remote.setOffline(false)
        try await Task.sleep(for: .milliseconds(1100))
        try await engine.processPending(waitForQuiet: true)
        let recovered = try await engine.status()
        XCTAssertEqual(recovered.pending, 0)
        XCTAssertEqual(recovered.phase, "idle")
        XCTAssertNil(recovered.lastError)
        XCTAssertEqual(recovered.publishedRevision, recovered.localRevision)
        await store.close()
    }

    func testAheadUploadKeepsPublicationOrderedAndSharesPendingPayload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        _ = try await store.create(parentID: volume.rootID, name: "older", kind: .directory)
        let source = root.appendingPathComponent("fixture")
        let bytes = Data("prepare before publication".utf8)
        try bytes.write(to: source)
        let operationID = UUID()
        let file = try await engine.createFromSource(parentID: volume.rootID, name: "newer",
            source: ResidentSourceIdentity.capture(url: source), operationID: operationID)
        await remote.configure(uploadDelay: true)

        let ahead = Task { await engine.prepareManagedPayloadsAhead() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await remote.startedUploads() == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await remote.startedUploads()
        XCTAssertEqual(started, 1)
        let before = try await store.volume()
        XCTAssertEqual(before.publishedRevision, volume.publishedRevision)
        let ordered = Task { try await engine.processPending() }
        await ahead.value
        try await ordered.value

        let total = await remote.startedUploads()
        let after = try await store.volume()
        let proof = try await store.publishedLocator(nodeID: file.id, generation: file.contentGeneration)
        let published = try XCTUnwrap(proof)
        let remoteBytes = await remote.bytes(published.key)
        XCTAssertEqual(total, 1, "Overlapping preparation and publication must share one upload")
        XCTAssertEqual(after.publishedRevision, after.revision)
        XCTAssertEqual(remoteBytes, bytes)
        await store.close()
    }

    func testAheadUploadPreparesNextFilesWhileOlderCommitIsBlockedInDeepBacklog() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        _ = try await store.create(parentID: volume.rootID, name: "first", kind: .directory)
        let source = root.appendingPathComponent("fixture")
        let bytes = Data("ready to send during the first commit".utf8)
        try bytes.write(to: source)
        let identity = try ResidentSourceIdentity.capture(url: source)
        var nextFiles: [NamespaceNode] = []
        for index in 0..<17 {
            nextFiles.append(try await engine.createFromSource(parentID: volume.rootID, name: "next-\(index)",
                source: identity, operationID: UUID()))
        }
        // Push the next files entirely out of the old newest-first window.
        for index in 0..<512 {
            _ = try await store.create(parentID: volume.rootID, name: "later-\(index)", kind: .directory)
        }
        _ = try await engine.createFromSource(parentID: volume.rootID, name: "last", source: identity, operationID: UUID())
        await remote.blockNextPublication()
        let publisher = Task { try await engine.processPending(limit: 1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await remote.publicationIsBlocked()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let blocked = await remote.publicationIsBlocked()
        await engine.prepareManagedPayloadsAhead()
        let stillBlocked = await remote.publicationIsBlocked()
        let uploads = await remote.startedUploads()
        let before = try? await store.volume()
        await remote.releasePublication()
        try await publisher.value

        XCTAssertTrue(blocked && stillBlocked)
        XCTAssertEqual(before?.publishedRevision, volume.publishedRevision)
        XCTAssertEqual(uploads, nextFiles.count, "Refill past the first 16 candidates without sending the tail file")
        try await engine.processPending(limit: nextFiles.count * 2)
        let finalUploads = await remote.startedUploads()
        XCTAssertEqual(finalUploads, nextFiles.count, "Publication must reuse the uploaded receipts")
        for file in nextFiles {
            let locator = try await store.publishedLocator(nodeID: file.id, generation: file.contentGeneration)
            let uploaded = await remote.bytes(try XCTUnwrap(locator).key)
            XCTAssertEqual(uploaded, bytes)
        }
        await store.close()
    }

    func testFoldedFinderWritesUseEightParallelFilesAndReplayPreparedRuns() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, cache, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        var nodes: [NamespaceNode] = []
        for index in 0..<10 { nodes.append(try await store.create(parentID: volume.rootID, name: "file-\(index)", kind: .file)) }
        try await engine.processPending()
        let baseline = try await store.volume().publishedRevision
        for node in nodes {
            for offset in 0..<4 { _ = try await engine.write(nodeID: node.id, offset: Int64(offset), data: Data([UInt8(offset)])) }
        }
        await remote.configure(uploadDelay: true)
        await remote.rejectPublications(true)
        do { try await engine.processPending(limit: 128); XCTFail("Publication must fail") } catch StorageFailure.conflict {}
        let peak = await remote.uploadPeak(), uploaded = await remote.startedUploads()
        XCTAssertEqual(peak, 8); XCTAssertEqual(uploaded, 8)
        let failed = try await store.volume()
        XCTAssertEqual(failed.publishedRevision, baseline)
        // Reopen the journal: prepared groups must keep their fixed endpoints and
        // reuse uploaded receipts instead of uploading intermediate generations.
        await store.close()
        let reopened = try NamespaceStore(directory: root.appendingPathComponent("namespace"), binding: "synthetic", mode: .managed)
        let resumed = SyncEngine(store: reopened, content: content, cache: cache, remote: remote, prefix: "Drive", mode: .managed)
        await remote.rejectPublications(false)
        try await resumed.resume()
        let final = try await reopened.volume(), count = await remote.startedUploads()
        XCTAssertEqual(final.publishedRevision, final.revision)
        XCTAssertEqual(count, 10)
        for node in nodes {
            let bytes = try await resumed.read(nodeID: node.id, offset: 0, length: 4)
            XCTAssertEqual(bytes, Data([0, 1, 2, 3]))
        }
        await reopened.close()
    }

    func testManagedPreparationIsConcurrentButHeadFailureCannotAdvanceFrontier() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        var nodes: [NamespaceNode] = []
        for index in 0..<3 { nodes.append(try await store.create(parentID: volume.rootID, name: "file-\(index)", kind: .file)) }
        try await engine.processPending()
        let baseline = try await store.volume().publishedRevision
        for node in nodes { _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("accepted".utf8)) }
        await remote.configure(uploadDelay: true); await remote.rejectPublications(true)
        do { try await engine.processPending(); XCTFail("HEAD conflict must stop publication") } catch StorageFailure.conflict {}
        let peak = await remote.uploadPeak(), current = try await store.volume()
        let operations = try await store.operations(limit: 10)
        XCTAssertEqual(peak, 3); XCTAssertEqual(current.publishedRevision, baseline)
        XCTAssertEqual(operations.first?.state, .attention)
        XCTAssertTrue(operations.dropFirst().allSatisfy { $0.state == .pending })
        for operation in operations {
            let receipts = try await store.receipts(operationID: operation.id)
            XCTAssertTrue(receipts.contains { $0.stepID == "uploaded" })
            XCTAssertFalse(receipts.contains { $0.stepID == "finished" })
        }
        let uploads = await remote.startedUploads()
        await remote.rejectPublications(false)
        try await engine.resume()
        let final = try await store.volume(), finalUploads = await remote.startedUploads()
        XCTAssertEqual(final.publishedRevision, final.revision); XCTAssertEqual(finalUploads, uploads)
        for node in nodes { let bytes = try await engine.read(nodeID: node.id, offset: 0, length: 8); XCTAssertEqual(bytes, Data("accepted".utf8)) }
        await store.close()
    }

    func testManagedConsecutiveWritesPublishOnceAndRetainHeldGenerationAcrossConflict() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, content, _, engine) = try setup(root, remote: remote, mode: .managed)
        let node = try await store.create(parentID: store.volume().rootID, name: "takes", kind: .file)
        try await engine.processPending()
        let baseline = try await store.volume().publishedRevision
        let firstRequest = UUID()
        let first = try await engine.write(nodeID: node.id, offset: 0, data: Data("a".utf8), operationID: firstRequest)
        let lease = await engine.retain(node: first)
        for i in 1..<36 { _ = try await engine.write(nodeID: node.id, offset: Int64(i), data: Data([UInt8(i)])) }
        await remote.rejectPublications(true)
        do { try await engine.processPending(limit: 2); XCTFail("conflict must retain the whole group") } catch StorageFailure.conflict { }
        let before = try await store.volume()
        XCTAssertEqual(before.publishedRevision, baseline)
        let queued = try await store.operations()
        XCTAssertEqual(queued.count, 36)
        let count = await remote.startedUploads()
        XCTAssertEqual(count, 1)
        // A later generation must not alter the fixed group on retry.
        _ = try await engine.write(nodeID: node.id, offset: 36, data: Data([36]))
        await remote.rejectPublications(false)
        try await engine.resume()
        let countAfter = await remote.startedUploads()
        XCTAssertEqual(countAfter, 2)
        let held = try await engine.read(node: first, offset: 0, length: 1)
        XCTAssertEqual(held, Data("a".utf8))
        let replay = try await engine.write(nodeID: node.id, offset: 0, data: Data("a".utf8), operationID: firstRequest)
        XCTAssertEqual(replay.contentGeneration, first.contentGeneration)
        await engine.release(token: lease)
        let complete = try await store.volume()
        XCTAssertEqual(complete.revision, complete.publishedRevision)
        let stored = await content.accounting()
        XCTAssertEqual(stored.snapshotCount, 0)
        let bytes = try await engine.read(nodeID: node.id, offset: 0, length: 37)
        XCTAssertEqual(bytes, Data([97] + (1...36).map(UInt8.init)))
        await store.close()
    }

    func testManagedPauseAfterPreparationKeepsAllAcceptedGenerationsPending() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        var nodes: [NamespaceNode] = []
        for index in 0..<3 { nodes.append(try await store.create(parentID: volume.rootID, name: "file-\(index)", kind: .file)) }
        try await engine.processPending()
        let baseline = try await store.volume().publishedRevision
        for node in nodes { _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("pending".utf8)) }
        await remote.configure(uploadDelay: true)
        let job = Task { try await engine.processPending() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await remote.startedUploads() < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await engine.requestPause(); try await job.value
        let status = try await engine.status(), operations = try await store.operations(limit: 10)
        XCTAssertEqual(status.phase, "paused"); XCTAssertEqual(status.publishedRevision, baseline)
        XCTAssertEqual(operations.count, 3); XCTAssertTrue(operations.allSatisfy { $0.state == .pending })
        XCTAssertGreaterThan(status.dirtyBytes, 0)
        try await engine.resume()
        let final = try await engine.status(); XCTAssertEqual(final.pending, 0)
        await store.close()
    }

    func testExtentSplitCannotExceedRestartManifestLimitAndFullReplacementAtLimitWorks() throws {
        let id = UUID()
        let extents = (0..<65535).map { index in ContentExtent(offset: Int64(index * 4), length: 4, fileID: id, storedLength: 4, checksum: "test") }
        XCTAssertThrowsError(try ContentStore.extentsAfterReplacing(extents, range: 1..<2)) { XCTAssertEqual($0 as? StorageFailure, .localStorageFull) }
        var full = extents; full.append(ContentExtent(offset: 262140, length: 4, fileID: id, storedLength: 4, checksum: "test"))
        let replaced = try ContentStore.extentsAfterReplacing(full, range: 0..<4)
        XCTAssertEqual(replaced.count, 65535)
        let split = try ContentStore.extentsAfterReplacing(Array(extents.prefix(1)), range: 1..<2)
        XCTAssertEqual(split.map(\.length), [1, 2]); XCTAssertEqual(split.last?.fileOffset, 2)
    }

    func testManagedRecoveryRejectsDecodedBudgetBeforeExposingPartialRecords() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        _ = try await store.create(parentID: volume.rootID, name: "recoverable", kind: .file)
        try await engine.processPending()
        let publisher = ManagedManifestPublisher(remote: remote, prefix: "Drive", volumeID: volume.id)
        do { _ = try await publisher.exportRecords(maximumDecodedBytes: 1); XCTFail("decoded byte budget must reject the snapshot") } catch StorageFailure.localStorageFull {}
        do { _ = try await publisher.exportRecords(maximumRecords: 1); XCTFail("record budget must reject the snapshot") } catch StorageFailure.localStorageFull {}
        let records = try await publisher.exportRecords()
        XCTAssertEqual(records.count, 2)
        await store.close()
    }

    func testManagedPreparationWindowBoundsManyUploads() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = FaultStorage(), (store, _, _, engine) = try setup(root, remote: remote, mode: .managed)
        let volume = try await store.volume()
        var nodes: [NamespaceNode] = []
        for index in 0..<12 { nodes.append(try await store.create(parentID: volume.rootID, name: "bounded-\(index)", kind: .file)) }
        try await engine.processPending()
        for node in nodes { _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("content".utf8)) }
        await remote.configure(uploadDelay: true)
        try await engine.processPending()
        let peak = await remote.uploadPeak(), uploads = await remote.startedUploads(), final = try await engine.status()
        XCTAssertEqual(peak, 8); XCTAssertEqual(uploads, 12)
        XCTAssertEqual(final.pending, 0); XCTAssertEqual(final.localRevision, final.publishedRevision)
        await store.close()
    }

}


private extension NamespaceStore {
    func rejectBatchCompletionForTesting(_ enabled: Bool) {
        let db = database
        database.beforeCommitForTesting = enabled ? {
            if try db.scalar("SELECT COUNT(*) FROM operations WHERE state='complete'") > 0 { throw NamespaceFailure.storage }
        } : nil
    }
    func injectBrokenAdmissionFence(_ broken: Bool) {
        database.admissionBarrier = broken ? { _ in throw StorageFailure.integrity } : CoreFileIO.requireMediaBarrier
    }
}
