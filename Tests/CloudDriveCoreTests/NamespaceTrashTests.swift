import XCTest
@testable import CloudDriveCore

final class NamespaceTrashTests: XCTestCase {
    private func equal<T: Equatable>(_ a: T, _ b: T) { XCTAssertEqual(a, b) }
    func testTrashRetainsIdentityHidesSearchAndRestoresAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = try NamespaceStore(directory: directory, binding: "trash")
        let root = try await store.volume().rootID
        let folder = try await store.create(parentID: root, name: "Album", kind: .directory)
        let file = try await store.create(parentID: folder.id, name: "song.wav", kind: .file)
        let request = UUID()
        let entry = try await store.moveToTrash(nodeID: folder.id, operationID: request)
        equal(try await store.node(file.id).id, file.id)
        equal(try await store.searchNames(text: "song").count, 0)
        equal(try await store.lookup(parentID: root, name: "Album"), nil)
        let revision = try await store.volume().revision
        await store.close()
        store = try NamespaceStore(directory: directory, binding: "trash")
        equal(try await store.moveToTrash(nodeID: folder.id, operationID: request).id, entry.id)
        equal(try await store.volume().revision, revision)
        equal(try await store.trashEntries().entries.count, 1)
        let restoreID = UUID()
        equal(try await store.restoreFromTrash(containerID: entry.id, operationID: restoreID).id, folder.id)
        equal(try await store.resolvedPath(file.id), "Album/song.wav")
        equal(try await store.trashEntries().entries.count, 0)
        let restoredRevision = try await store.volume().revision
        _ = try await store.restoreFromTrash(containerID: entry.id, operationID: restoreID)
        equal(try await store.volume().revision, restoredRevision)
        equal(try await store.searchNames(text: "song").count, 1)
        await store.close()
    }
    func testTrashTransactionRollbackAndRestoreCollisionPreserveBothFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "trash")
        let root = try await store.volume().rootID
        let file = try await store.create(parentID: root, name: "a", kind: .file)
        let before = try await store.volume().revision
        await store.injectBeforeCommitFailureForTesting(true)
        do { _ = try await store.moveToTrash(nodeID: file.id, operationID: UUID()); XCTFail() } catch { equal(error as? NamespaceFailure, .storage) }
        await store.injectBeforeCommitFailureForTesting(false)
        equal(try await store.volume().revision, before)
        equal(try await store.lookup(parentID: root, name: "a")?.id, file.id)
        equal(try await store.lookup(parentID: root, name: NamespaceStore.trashDirectoryName), nil)
        let entry = try await store.moveToTrash(nodeID: file.id, operationID: UUID())
        let replacement = try await store.create(parentID: root, name: "a", kind: .file)
        do { _ = try await store.restoreFromTrash(containerID: entry.id, operationID: UUID()); XCTFail() } catch { equal(error as? NamespaceFailure, .collision) }
        equal(try await store.lookup(parentID: root, name: "a")?.id, replacement.id)
        equal(try await store.trashEntries().entries.first?.node.id, file.id)
        let customRestoreID = UUID()
        _ = try await store.restoreFromTrash(containerID: entry.id, name: "a restored", operationID: customRestoreID)
        _ = try await store.restoreFromTrash(containerID: entry.id, name: "a restored", operationID: customRestoreID)
        do { _ = try await store.restoreFromTrash(containerID: entry.id, operationID: customRestoreID); XCTFail() }
        catch { equal(error as? NamespaceFailure, .invalidTransition) }
        equal(try await store.lookup(parentID: root, name: "a restored")?.id, file.id)
        await store.close()
    }
    func testActivityIncludesDurableStatesAndBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "activity")
        let root = try await store.volume().rootID
        _ = try await store.create(parentID: root, name: "first", kind: .file)
        _ = try await store.create(parentID: root, name: "second", kind: .file)
        let activity = try await store.activity(limit: 1)
        equal(activity.count, 1); equal(activity.first?.name, "first"); equal(activity.first?.state, .pending)
        await store.close()
    }

    func testTrashRestorePublishesCorrectBytesInBothModes() async throws {
        for mode in [NamespaceStorageMode.compatible, .managed] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let remote = try FixtureStorageRemote(directory: directory.appendingPathComponent("Remote"))
            let store = try NamespaceStore(directory: directory.appendingPathComponent("Namespace"), binding: "trash", mode: mode)
            let content = try ContentStore(directory: directory.appendingPathComponent("Content"))
            let cache = try RangeCache(directory: directory.appendingPathComponent("Cache"))
            let sync = SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: "fixture", mode: mode)
            let root = try await store.volume().rootID
            if mode == .managed { try await sync.publishInitialNamespace() }
            let file = try await store.create(parentID: root, name: "retained.txt", kind: .file)
            _ = try await sync.write(nodeID: file.id, offset: 0, data: Data("precious bytes".utf8))
            try await sync.processPending()
            let entry = try await store.moveToTrash(nodeID: file.id, operationID: UUID())
            try await sync.processPending()
            equal(try await store.operations().count, 0)
            equal(try await sync.read(nodeID: file.id, offset: 0, length: 14), Data("precious bytes".utf8))
            _ = try await store.restoreFromTrash(containerID: entry.id, operationID: UUID())
            try await sync.processPending()
            equal(try await store.operations().count, 0)
            equal(try await sync.read(nodeID: file.id, offset: 0, length: 14), Data("precious bytes".utf8))
            if mode == .compatible { equal(try await remote.head(key: "fixture/retained.txt")?.size, 14) }
            await store.close()
        }
    }

    func testVerifiedRelocationCanReturnToOldIdentityAndStayBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = try ContentStore(directory: directory)
        let a = ObjectLocator(key: "a", validator: "same-bytes", size: 12)
        let b = ObjectLocator(key: "b", validator: "same-bytes", size: 12)
        try await content.recordVerifiedRelocation(source: a, destination: b)
        try await content.recordVerifiedRelocation(source: b, destination: a)
        equal(try await content.resolve(b), a)
        equal(try await content.resolve(a), a)
        var previous = a
        for index in 0..<150 {
            let next = ObjectLocator(key: "move-\(index)", validator: "same-bytes", size: 12)
            try await content.recordVerifiedRelocation(source: previous, destination: next)
            previous = next
        }
        equal(try await content.resolve(a), previous)
        equal(try await content.resolve(b), previous)
        // Invalid barriers must roll back the temporary terminal changes too.
        do { try await content.recordVerifiedRelocation(source: previous, destination: .init(key: "a", validator: "same-bytes", size: 9)); XCTFail() }
        catch { equal(error as? StorageFailure, .integrity) }
        equal(try await content.resolve(a), previous)
    }
    func testExplicitPurgeIsDurableBoundToContainerAndNeverReplaysAsRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = try NamespaceStore(directory: directory, binding: "purge")
        let root = try await store.volume().rootID
        let file = try await store.create(parentID: root, name: "a", kind: .file)
        let entry = try await store.moveToTrash(nodeID: file.id, operationID: UUID())
        let request = UUID(), operation = try await store.purgeTrash(containerID: entry.id, operationID: request)
        equal(operation.kind, .remove); equal(operation.nodeID, entry.id)
        equal(try await store.trashEntries().entries.count, 0)
        let revision = try await store.volume().revision
        do { _ = try await store.node(file.id); XCTFail() } catch { equal(error as? NamespaceFailure, .notFound) }
        await store.close(); store = try NamespaceStore(directory: directory, binding: "purge")
        equal(try await store.purgeTrash(containerID: entry.id, operationID: request).id, operation.id)
        equal(try await store.volume().revision, revision)
        do { _ = try await store.purgeTrash(containerID: root, operationID: request); XCTFail() } catch { equal(error as? NamespaceFailure, .invalidTransition) }
        do { _ = try await store.restoreFromTrash(containerID: entry.id, operationID: UUID()); XCTFail() } catch { equal(error as? NamespaceFailure, .notFound) }
        await store.close()
    }

    func testPurgeRejectsForeignSelectionAndCommitFailureKeepsRetainedItem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "purge")
        let root = try await store.volume().rootID, file = try await store.create(parentID: root, name: "keep", kind: .file)
        do { _ = try await store.purgeTrash(containerID: file.id, operationID: UUID()); XCTFail() } catch { equal(error as? NamespaceFailure, .notFound) }
        let entry = try await store.moveToTrash(nodeID: file.id, operationID: UUID()), revision = try await store.volume().revision
        await store.injectBeforeCommitFailureForTesting(true)
        do { _ = try await store.purgeTrash(containerID: entry.id, operationID: UUID()); XCTFail() } catch { equal(error as? NamespaceFailure, .storage) }
        await store.injectBeforeCommitFailureForTesting(false)
        equal(try await store.volume().revision, revision); equal(try await store.trashEntries().entries.first?.node.id, file.id)
        _ = try await store.create(parentID: entry.id, name: "foreign", kind: .file)
        do { _ = try await store.purgeTrash(containerID: entry.id, operationID: UUID()); XCTFail() } catch { equal(error as? NamespaceFailure, .invalidTransition) }
        equal(try await store.node(file.id).id, file.id)
        await store.close()
    }

    func testPurgePublishesInBothModesAndPreservesOpenGenerations() async throws {
        for mode in [NamespaceStorageMode.compatible, .managed] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let remote = try FixtureStorageRemote(directory: directory.appendingPathComponent("Remote"))
            let store = try NamespaceStore(directory: directory.appendingPathComponent("Namespace"), binding: "purge", mode: mode)
            let content = try ContentStore(directory: directory.appendingPathComponent("Content")), cache = try RangeCache(directory: directory.appendingPathComponent("Cache"))
            let sync = SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: "fixture", mode: mode)
            let volume = try await store.volume()
            if mode == .managed { try await sync.publishInitialNamespace() }
            let folder = try await store.create(parentID: volume.rootID, name: "folder", kind: .directory)
            let file = try await store.create(parentID: folder.id, name: "child", kind: .file)
            _ = try await sync.write(nodeID: file.id, offset: 0, data: Data("retained bytes".utf8))
            try await sync.processPending()
            let captured = try await store.node(file.id), lease = await sync.retain(node: captured)
            let entry = try await store.moveToTrash(nodeID: folder.id, operationID: UUID())
            // Purge while its preceding remote move is still pending: durable
            // dependencies must finish the copy before executing the remove.
            _ = try await store.purgeTrash(containerID: entry.id, operationID: UUID())
            try await sync.processPending()
            equal(try await store.operations().count, 0)
            equal(try await sync.read(node: captured, offset: 0, length: 14), Data("retained bytes".utf8))
            equal(try await store.trashEntries().entries.count, 0)
            if mode == .managed {
                let publisher = ManagedManifestPublisher(remote: remote, prefix: "fixture", volumeID: volume.id)
                let records = try await publisher.exportRecords()
                XCTAssertFalse(records.contains { $0.id == file.id || $0.id == folder.id || $0.id == entry.id })
            } else {
                let visible = try await remote.list(prefix: "fixture/" + NamespaceStore.trashDirectoryName + "/", cursor: nil, limit: 100)
                XCTAssertFalse(visible.objects.contains { $0.key.contains(entry.node.name + "/child") })
            }
            await sync.release(token: lease); await store.close()
        }
    }

    func testRestoringQueuesEmptyWrapperCleanupWithoutBreakingReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "cleanup")
        let root = try await store.volume().rootID, file = try await store.create(parentID: root, name: "restore", kind: .file)
        let entry = try await store.moveToTrash(nodeID: file.id, operationID: UUID()), request = UUID()
        _ = try await store.restoreFromTrash(containerID: entry.id, operationID: request)
        let operations = try await store.operations(), cleanup = try XCTUnwrap(operations.last)
        equal(cleanup.kind, .remove); equal(cleanup.nodeID, entry.id)
        XCTAssertTrue(cleanup.dependencies.contains(request))
        let revision = try await store.volume().revision
        equal(try await store.restoreFromTrash(containerID: entry.id, operationID: request).id, file.id)
        equal(try await store.volume().revision, revision)
        await store.close()
    }

}
