import XCTest
import Foundation
import SQLite3
@testable import CloudDriveCore

private actor MigrationStorage: StorageRemote {
    private struct Value { var object: StorageObject; var data: Data }
    private var values: [String: Value] = [:]
    private var sequence = 0
    private var payloadReads = 0
    private var metadataReads = 0
    private var puts = 0
    private var copies = 0
    private var deletes = 0
    private var pageSize = 1000
    private var failCopyReply = false
    private var blockCopy = false
    private var copyStarted = false
    private var copyWaiter: CheckedContinuation<Void, Never>?
    private var checkpointCollision: URL?
    func seed(_ key: String, _ data: Data) throws -> StorageObject { try put(key: key, data: data, condition: .unconditional, operationID: UUID()) }
    func configure(pageSize: Int? = nil, loseCopyReply: Bool? = nil, blockCopy: Bool? = nil, checkpointCollision: URL? = nil) {
        if let pageSize { self.pageSize = pageSize }
        if let loseCopyReply { failCopyReply = loseCopyReply }
        if let blockCopy { self.blockCopy = blockCopy }
        self.checkpointCollision = checkpointCollision
    }
    func counts() -> (payload: Int, metadata: Int, puts: Int, copies: Int, deletes: Int) { (payloadReads, metadataReads, puts, copies, deletes) }
    func resetCounts() { payloadReads = 0; metadataReads = 0; puts = 0; copies = 0; deletes = 0 }
    func bytes(_ key: String) -> Data? { values[key]?.data }
    func keys() -> [String] { values.keys.sorted() }
    func didStartCopy() -> Bool { copyStarted }
    func releaseCopy() { blockCopy = false; copyWaiter?.resume(); copyWaiter = nil }
    func head(key: String) -> StorageObject? { values[key]?.object }
    func read(key: String, range: Range<Int64>, validator: String) throws -> StorageRange {
        if key.contains("/.clouddrive/v1/") && !key.contains("/.clouddrive/v1/content/") { metadataReads += 1 } else { payloadReads += 1 }
        guard let value = values[key] else { throw StorageFailure.notFound }
        guard value.object.validator == validator else { throw StorageFailure.conflict }
        guard range.lowerBound >= 0, range.upperBound <= value.object.size else { throw StorageFailure.invalidRange }
        return StorageRange(data: value.data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), offset: range.lowerBound, totalSize: value.object.size, validator: validator)
    }
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) throws -> StorageObject {
        switch condition {
        case .absent: guard values[key] == nil else { throw StorageFailure.conflict }
        case .matches(let tag): guard values[key]?.object.validator == tag else { throw StorageFailure.conflict }
        case .unconditional: break
        }
        sequence += 1; puts += 1
        let object = StorageObject(key: key, size: Int64(data.count), validator: "v\(sequence)", checksum: CoreFileIO.hash(data), operationID: operationID, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        values[key] = Value(object: object, data: data); return object
    }
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) async throws -> StorageObject {
        copyStarted = true
        if blockCopy { await withCheckedContinuation { copyWaiter = $0 } }
        guard let value = values[source], value.object.validator == sourceValidator else { throw StorageFailure.conflict }
        if let existing = values[destination] {
            guard existing.object.operationID == operationID, existing.data == value.data else { throw StorageFailure.conflict }
            return existing.object
        }
        let object = try put(key: destination, data: value.data, condition: .absent, operationID: operationID)
        copies += 1
        if failCopyReply { failCopyReply = false; throw StorageFailure.unknownOutcome }
        return object
    }
    func delete(key: String, validator: String) throws {
        guard let old = values[key], old.object.validator == validator else { throw StorageFailure.conflict }
        values.removeValue(forKey: key); deletes += 1
    }
    func list(prefix: String, cursor: String?, limit: Int) throws -> StoragePage {
        if let collision = checkpointCollision {
            checkpointCollision = nil
            try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let matches = values.values.map(\.object).filter { $0.key.hasPrefix(prefix) && (cursor == nil || $0.key > cursor!) }.sorted { $0.key < $1.key }
        let result = Array(matches.prefix(min(pageSize, limit)))
        return StoragePage(objects: result, nextCursor: matches.count > result.count ? result.last?.key : nil)
    }
}

final class NamespaceMigrationTests: XCTestCase {
    private func equal<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(actual, expected, file: file, line: line) }
    private func truth(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func required<T>(_ value: T?) throws -> T { guard let value else { throw StorageFailure.notFound }; return value }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-migration-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return root
    }
    private struct ManagedFixture {
        let directory: URL
        let remote: MigrationStorage
        let store: NamespaceStore
        let content: ContentStore
        let cache: RangeCache
        let sync: SyncEngine
        let rootID: UUID
        let folder: NamespaceNode
        let file: NamespaceNode
    }
    private func managed() async throws -> ManagedFixture {
        let root = try directory(), remote = MigrationStorage()
        let object = try await remote.seed("Drive/Album/song.bin", Data("payload".utf8))
        let store = try NamespaceStore(directory: root.appendingPathComponent("Source/Namespace"), binding: "synthetic", mode: .managed)
        try await store.importEntries([.init(path: "Album/song.bin", size: object.size, modifiedAt: object.modifiedAt!, backing: .init(key: object.key, validator: object.validator, size: object.size, checksum: object.checksum)), .init(path: "Album/empty.bin"), .init(path: "Empty", kind: .directory)])
        let volume = try await store.volume(), folder = try required(try await store.lookup(parentID: volume.rootID, name: "Album")), file = try required(try await store.lookup(parentID: folder.id, name: "song.bin"))
        let content = try ContentStore(directory: root.appendingPathComponent("Source/Content"), maximumBytes: 1024*1024)
        let cache = try RangeCache(directory: root.appendingPathComponent("Source/Cache"), maximumBytes: 64*1024, chunkSize: 4096)
        let sync = SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: "Drive", mode: .managed)
        try await sync.publishInitialNamespace()
        return ManagedFixture(directory: root, remote: remote, store: store, content: content, cache: cache, sync: sync, rootID: volume.rootID, folder: folder, file: file)
    }
    func testMetadataImportReplaysPageCommittedBeforeCheckpointWithoutDownloadingPayloads() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = MigrationStorage()
        _ = try await remote.seed("Drive/Album/a.bin", Data("first".utf8)); _ = try await remote.seed("Drive/Album/b.bin", Data("second".utf8))
        let keys = await remote.keys(), store = try NamespaceStore(directory: root.appendingPathComponent("Namespace"), binding: "synthetic")
        let checkpoint = root.appendingPathComponent("namespace-import.json")
        await remote.configure(pageSize: 1, checkpointCollision: checkpoint)
        let migration = NamespaceMigration(store: store, remote: remote, prefix: "Drive", directory: root)
        do { _ = try await migration.importCompatible(); XCTFail("Checkpoint collision must fail after metadata commit") }
        catch { /* The first page is durable even though its cursor was not. */ }
        let volume = try await store.volume(), folder = try required(try await store.lookup(parentID: volume.rootID, name: "Album")), first = try required(try await store.lookup(parentID: folder.id, name: "a.bin"))
        try FileManager.default.removeItem(at: checkpoint)
        let resumed = NamespaceMigration(store: store, remote: remote, prefix: "Drive", directory: root)
        let progress = try await resumed.importCompatible()
        truth(progress.complete); equal(progress.objects, 2); equal(progress.bytes, 11)
        equal(try await store.lookup(parentID: folder.id, name: "a.bin")?.id, first.id)
        let counts = await remote.counts(); equal(counts.payload, 0); equal(counts.metadata, 0); equal(counts.deletes, 0)
        equal(await remote.keys(), keys)
        let repeatProgress = try await resumed.importCompatible(); equal(repeatProgress, progress)
    }
    func testReservedPrefixCollisionPreservesExistingMetadataAndRemoteObjects() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = MigrationStorage()
        _ = try await remote.seed("Drive/.clouddrive/v1/HEAD", Data("foreign reserved format".utf8))
        _ = try await remote.seed("Drive/ordinary.bin", Data("ordinary".utf8))
        let store = try NamespaceStore(directory: root.appendingPathComponent("Namespace"), binding: "synthetic")
        try await store.importEntries([.init(path: "keep.bin")])
        let volume = try await store.volume(), keep = try required(try await store.lookup(parentID: volume.rootID, name: "keep.bin")), keys = await remote.keys()
        let migration = NamespaceMigration(store: store, remote: remote, prefix: "Drive", directory: root)
        do { _ = try await migration.importCompatible(); XCTFail("Reserved metadata must not be imported as a user file") }
        catch { equal(error as? NamespaceFailure, .collision) }
        equal(try await store.lookup(parentID: volume.rootID, name: "keep.bin")?.id, keep.id)
        equal(await remote.keys(), keys)
        let progress = try await migration.progress(); XCTAssertFalse(progress.complete)
        equal((await remote.counts()).payload, 0); equal((await remote.counts()).deletes, 0)
    }
    func testRecognizedCompatibleFormatSkipsPrivateObjectsWithoutPayloadReads() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = MigrationStorage()
        let marker: [String: Any] = ["version": 1, "binding": "synthetic", "mode": "compatible", "volumeID": UUID().uuidString]
        _ = try await remote.seed("Drive/.clouddrive/v1/FORMAT", JSONSerialization.data(withJSONObject: marker))
        _ = try await remote.seed("Drive/.clouddrive/v1/backups/private", Data("private".utf8))
        _ = try await remote.seed("Drive/ordinary.bin", Data("ordinary".utf8))
        await remote.resetCounts()
        let store = try NamespaceStore(directory: root.appendingPathComponent("Namespace"), binding: "synthetic")
        let migration = NamespaceMigration(store: store, remote: remote, prefix: "Drive", directory: root)
        let progress = try await migration.importCompatible()
        truth(progress.complete); equal(progress.objects, 1); equal(progress.bytes, 8)
        let volume = try await store.volume()
        equal(try await store.lookup(parentID: volume.rootID, name: ".clouddrive"), nil)
        let counts = await remote.counts(); equal(counts.payload, 0); equal(counts.deletes, 0); equal(counts.metadata, 1)
    }
    func testForeignCompatibleFormatFailsClosed() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = MigrationStorage()
        let marker: [String: Any] = ["version": 1, "binding": "another-account", "mode": "compatible", "volumeID": UUID().uuidString]
        _ = try await remote.seed("Drive/.clouddrive/v1/FORMAT", JSONSerialization.data(withJSONObject: marker))
        let store = try NamespaceStore(directory: root.appendingPathComponent("Namespace"), binding: "synthetic")
        let migration = NamespaceMigration(store: store, remote: remote, prefix: "Drive", directory: root)
        do { _ = try await migration.importCompatible(); XCTFail("Foreign FORMAT must be rejected") }
        catch { equal(error as? NamespaceFailure, .collision) }
        equal((await remote.counts()).deletes, 0)
    }
    func testManagedRemoteRecoveryReconstructsStableNodeAndVolumeIdentityWithoutPayloadReads() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        await f.remote.resetCounts()
        let destination = f.directory.appendingPathComponent("Recovered")
        let restored = try await NamespaceRecovery.restoreManaged(remote: f.remote, prefix: "Drive", directory: destination, binding: "synthetic")
        let sourceVolume = try await f.store.volume(), recoveredVolume = try await restored.volume(), file = try await restored.node(f.file.id)
        equal(recoveredVolume.id, sourceVolume.id); equal(recoveredVolume.rootID, sourceVolume.rootID)
        equal(file.id, f.file.id); equal(file.parentID, f.file.parentID); equal(file.backing, f.file.backing)
        equal(file.inode, f.file.inode)
        equal(try await restored.node(f.folder.id).inode, f.folder.inode)
        equal(try await restored.resolvedPath(file.id), "Album/song.bin")
        equal(recoveredVolume.revision, sourceVolume.revision); equal(recoveredVolume.publishedRevision, recoveredVolume.revision)
        equal((await f.remote.counts()).payload, 0); equal((await f.remote.counts()).deletes, 0)
        await restored.close()
    }
    func testRecoveryReplaysCommittedRestoreWhenFinalImportCheckpointFailed() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destination = f.directory.appendingPathComponent("Recovered")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let blocked = destination.appendingPathComponent("namespace-import.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { _ = try await NamespaceRecovery.restoreManaged(remote: f.remote, prefix: "Drive", directory: destination, binding: "synthetic"); XCTFail("Final checkpoint must fail") }
        catch { /* Recovery must retain the already committed store. */ }
        try FileManager.default.removeItem(at: blocked)
        let resumed = try await NamespaceRecovery.restoreManaged(remote: f.remote, prefix: "Drive", directory: destination, binding: "synthetic")
        equal(try await resumed.node(f.file.id).id, f.file.id)
        equal(try await resumed.resolvedPath(f.file.id), "Album/song.bin")
        truth(FileManager.default.fileExists(atPath: blocked.path))
        await resumed.close()
    }
    func testIncompleteRecoveryCheckpointVerifiesAndReusesCommittedNamespace() async throws {
        struct RecoveryCheckpoint: Codable { var binding: String; var head: ManagedHead; var headValidator: String; var rootID: UUID; var revision: Int64; var complete: Bool }
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destination = f.directory.appendingPathComponent("Recovered")
        let restored = try await NamespaceRecovery.restoreManaged(remote: f.remote, prefix: "Drive", directory: destination, binding: "synthetic")
        let original = try await restored.volume(); await restored.close()
        let checkpointURL = destination.appendingPathComponent("managed-recovery.json")
        var checkpoint = try CoreFileIO.readChecked(RecoveryCheckpoint.self, at: checkpointURL, maximum: 65_536)
        checkpoint.complete = false; try CoreFileIO.atomicChecked(checkpoint, at: checkpointURL)
        let replayed = try await NamespaceRecovery.restoreManaged(remote: f.remote, prefix: "Drive", directory: destination, binding: "synthetic")
        equal(try await replayed.volume(), original)
        equal(try await replayed.node(f.file.id).id, f.file.id)
        truth(try CoreFileIO.readChecked(RecoveryCheckpoint.self, at: checkpointURL, maximum: 65_536).complete)
        await replayed.close()
    }
    func testRecoveryRefusesForeignExistingStoreWithoutReplacingItsFiles() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destination = f.directory.appendingPathComponent("Foreign")
        let foreign = try NamespaceStore(directory: destination.appendingPathComponent("Namespace"), binding: "different-account")
        try await foreign.importEntries([.init(path: "keep.bin")])
        let volume = try await foreign.volume(), keep = try required(try await foreign.lookup(parentID: volume.rootID, name: "keep.bin")); await foreign.close()
        do { _ = try await NamespaceRecovery.restoreManaged(remote: f.remote, prefix: "Drive", directory: destination, binding: "synthetic"); XCTFail("Foreign store cannot be adopted") }
        catch { equal(error as? NamespaceFailure, .bindingMismatch) }
        let preserved = try NamespaceStore(directory: destination.appendingPathComponent("Namespace"), binding: "different-account")
        equal(try await preserved.volume().id, volume.id); equal(try await preserved.node(keep.id).id, keep.id)
        await preserved.close()
    }
    func testRecoveryRefusesNewerSchemaWithoutResettingDatabase() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destination = f.directory.appendingPathComponent("Future")
        let existing = try NamespaceStore(directory: destination.appendingPathComponent("Namespace"), binding: "synthetic", mode: .managed)
        try await existing.importEntries([.init(path: "keep.bin")]); await existing.close()
        let database = destination.appendingPathComponent("Namespace/namespace.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw StorageFailure.integrity }
        guard sqlite3_exec(handle, "PRAGMA user_version=999", nil, nil, nil) == SQLITE_OK else { sqlite3_close(handle); throw StorageFailure.integrity }
        sqlite3_close(handle)
        let hash = CoreFileIO.hash(try Data(contentsOf: database))
        do { _ = try await NamespaceRecovery.restoreManaged(remote: f.remote, prefix: "Drive", directory: destination, binding: "synthetic"); XCTFail("Future schema cannot be recreated") }
        catch { equal(error as? NamespaceFailure, .incompatibleSchema) }
        equal(CoreFileIO.hash(try Data(contentsOf: database)), hash)
    }
    func testPublishedManagedSnapshotExportsOrdinaryKeysWithVerifiedBytesAndNoSourceDeletion() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        await f.remote.resetCounts()
        let exporter = NamespaceExporter(store: f.store, content: f.content, remote: f.remote, prefix: "Drive", directory: f.directory.appendingPathComponent("Exports"))
        let progress = try await exporter.export(to: "Drive/Export")
        truth(progress.complete); equal(progress.files, 2); equal(progress.bytes, 7)
        equal(await f.remote.bytes("Drive/Export/Album/song.bin"), Data("payload".utf8))
        equal(await f.remote.bytes("Drive/Export/Album/empty.bin"), Data())
        equal(await f.remote.bytes("Drive/Export/Album/"), Data()); equal(await f.remote.bytes("Drive/Export/Empty/"), Data())
        equal(await f.remote.bytes("Drive/Album/song.bin"), Data("payload".utf8))
        equal((await f.remote.counts()).payload, 0); equal((await f.remote.counts()).deletes, 0)
        equal(try await f.store.volume().mode, .managed)
    }
    func testExportRefusesOccupiedDestinationWithoutOverwritingIt() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.remote.seed("Drive/Occupied/keep", Data("keep".utf8)); let keys = await f.remote.keys()
        await f.remote.resetCounts()
        let exporter = NamespaceExporter(store: f.store, content: f.content, remote: f.remote, prefix: "Drive", directory: f.directory.appendingPathComponent("Exports"))
        do { _ = try await exporter.export(to: "Drive/Occupied"); XCTFail("Occupied export prefix cannot be overwritten") }
        catch { equal(error as? StorageFailure, .conflict) }
        equal(await f.remote.keys(), keys); equal(await f.remote.bytes("Drive/Occupied/keep"), Data("keep".utf8))
        equal((await f.remote.counts()).puts, 0); equal((await f.remote.counts()).deletes, 0)
    }
    func testExportLostCopyReplyResumesDurableCheckpointWithoutDuplicatePhysicalCopy() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        await f.remote.configure(loseCopyReply: true); await f.remote.resetCounts()
        let checkpoint = f.directory.appendingPathComponent("Exports")
        let first = NamespaceExporter(store: f.store, content: f.content, remote: f.remote, prefix: "Drive", directory: checkpoint)
        do { _ = try await first.export(to: "Drive/Export"); XCTFail("Lost copy response must remain uncertain") }
        catch { equal(error as? StorageFailure, .unknownOutcome) }
        let resumed = NamespaceExporter(store: f.store, content: f.content, remote: f.remote, prefix: "Drive", directory: checkpoint)
        let progress = try await resumed.export(to: "Drive/Export")
        truth(progress.complete); equal(progress.files, 2); equal(progress.bytes, 7)
        equal((await f.remote.counts()).copies, 1)
        equal(await f.remote.bytes("Drive/Export/Album/song.bin"), Data("payload".utf8))
        equal((await f.remote.counts()).deletes, 0)
    }
    func testExportUsesAsOfPathsWhileLaterLocalRenameCommits() async throws {
        let f = try await managed(); defer { try? FileManager.default.removeItem(at: f.directory) }
        await f.remote.configure(blockCopy: true)
        let exporter = NamespaceExporter(store: f.store, content: f.content, remote: f.remote, prefix: "Drive", directory: f.directory.appendingPathComponent("Exports"))
        let task = Task { try await exporter.export(to: "Drive/Snapshot") }
        let deadline = Date().addingTimeInterval(2)
        while !(await f.remote.didStartCopy()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard await f.remote.didStartCopy() else { await f.remote.releaseCopy(); _ = try? await task.value; throw StorageFailure.busy }
        do { _ = try await f.store.rename(nodeID: f.folder.id, parentID: f.rootID, name: "Renamed") }
        catch { await f.remote.releaseCopy(); _ = try? await task.value; throw error }
        equal(try await f.store.resolvedPath(f.file.id), "Renamed/song.bin")
        await f.remote.releaseCopy()
        truth(try await task.value.complete)
        equal(await f.remote.bytes("Drive/Snapshot/Album/song.bin"), Data("payload".utf8))
        let unexpected = await f.remote.bytes("Drive/Snapshot/Renamed/song.bin"); XCTAssertNil(unexpected)
        equal((await f.remote.counts()).deletes, 0)
    }
}
