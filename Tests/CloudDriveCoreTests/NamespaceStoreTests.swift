import XCTest
import SQLite3
@testable import CloudDriveCore

final class NamespaceStoreTests: XCTestCase {
    func testStatusSummaryCountsBeyondTenThousandWithoutDecodingPayloads() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "summary")
        try await store.seedSummaryRowsForTesting()
        let summary = try await store.pendingOperationSummary()
        XCTAssertEqual(summary.count, 10_004)
        XCTAssertEqual(summary.attention, 3)
        XCTAssertEqual(summary.firstError, "offline")
        XCTAssertTrue(summary.attentionErrors.contains { $0 == nil })
        XCTAssertTrue(summary.attentionErrors.contains { $0 == "conflict" })
        await store.close()
    }
    private func assertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
    private func assertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotEqual(a, b, file: file, line: line) }
    private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func assertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(value, file: file, line: line) }
    private func assertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(value, file: file, line: line) }
    private func assertLessOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertLessThanOrEqual(a, b, file: file, line: line) }
    private func assertGreater<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertGreaterThan(a, b, file: file, line: line) }
    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("namespace-core-" + UUID().uuidString) }
    private func expect(_ failure: NamespaceFailure, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(failure)", file: file, line: line) }
        catch { assertEqual(error as? NamespaceFailure, failure, file: file, line: line) }
    }
    func testDirectoryPageIncludesCurrentDotInodesAndRevisionAfterMove() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "dots")
        let root = try await store.volume().rootID
        let rootPage = try await store.list(parentID: root, includeDotInodes: true)
        XCTAssertEqual(rootPage.dotInodes?.directory, rootPage.dotInodes?.parent)
        let parent = try await store.create(parentID: root, name: "parent", kind: .directory)
        let child = try await store.create(parentID: root, name: "child", kind: .directory)
        let before = try await store.list(parentID: child.id, includeDotInodes: true)
        _ = try await store.rename(nodeID: child.id, parentID: parent.id, name: "child")
        let after = try await store.list(parentID: child.id, includeDotInodes: true)
        XCTAssertNotEqual(before.revision, after.revision)
        XCTAssertEqual(before.dotInodes?.parent, rootPage.dotInodes?.directory)
        XCTAssertEqual(after.dotInodes?.directory, child.inode)
        XCTAssertEqual(after.dotInodes?.parent, parent.inode)
        await store.close()
    }
    func testVersionSixXattrUpgradePreservesPendingAndLegacyNodes() async throws {
        let dir = temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try NamespaceStore(directory: dir, binding: "upgrade", mode: .managed)
        let root = try await first.volume().rootID
        try await first.importEntries([.init(path: "sample"), .init(path: "._sample")])
        let pending = try await first.create(parentID: root, name: "pending", kind: .file)
        let revision = try await first.volume().revision
        await first.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dir.appendingPathComponent("namespace.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE nodes DROP COLUMN xattrs; PRAGMA user_version=6", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let upgraded = try NamespaceStore(directory: dir, binding: "upgrade", mode: .managed)
        assertEqual(try await upgraded.volume().revision, revision)
        assertEqual(try await upgraded.node(pending.id), pending)
        let legacy = try unwrap(try await upgraded.lookup(parentID: root, name: "sample"))
        XCTAssertNil(legacy.xattrs)
        let operations = try await upgraded.operations()
        XCTAssertEqual(operations.count, 1); XCTAssertEqual(operations[0].nodeID, pending.id)
        let new = try await upgraded.create(parentID: root, name: "new", kind: .file, nativeXattrs: true)
        XCTAssertEqual(new.xattrs, [:])
    }
    func testRenameKeepsIdentityBackingAndDurableRequestAcrossRestart() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        var store: NamespaceStore? = try NamespaceStore(directory: directory, binding: "fixture")
        let root = try await store!.volume().rootID
        try await store!.importEntries([.init(path: "Album/Sub/song.wav", size: 91, backing: .init(key: "old/Album/Sub/song.wav", validator: "version-1", size: 91))])
        let album = try unwrap(try await store!.lookup(parentID: root, name: "Album"))
        let sub = try unwrap(try await store!.lookup(parentID: album.id, name: "Sub"))
        let opened = try unwrap(try await store!.lookup(parentID: sub.id, name: "song.wav"))
        let request = UUID()
        let accepted = try await store!.rename(nodeID: album.id, parentID: root, name: "Moved", operationID: request)
        assertEqual(accepted.sourcePath, "Album"); assertEqual(accepted.destinationPath, "Moved")
        assertEqual(try await store!.node(album.id).modifiedAt, album.modifiedAt)
        assertEqual(try await store!.resolvedPath(opened.id), "Moved/Sub/song.wav")
        assertEqual(try await store!.resolvedLocator(opened.id), opened.backing)
        assertEqual(try await store!.node(inode: opened.inode).id, opened.id)
        let revision = try await store!.volume().revision
        await store!.close(); store = nil
        store = try NamespaceStore(directory: directory, binding: "fixture")
        assertEqual(try await store!.rename(nodeID: album.id, parentID: root, name: "Moved", operationID: request), accepted)
        assertEqual(try await store!.volume().revision, revision)
        assertEqual(try await store!.operations().count, 1)
        await expect(.invalidTransition) { _ = try await store!.rename(nodeID: album.id, parentID: root, name: "Other", operationID: request) }
        await store!.close()
    }
    func testMutationAndJournalRollbackTogetherAtCommitFailure() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture")
        let root = try await store.volume().rootID
        try await store.importEntries([.init(path: "Before/file", backing: .init(key: "Before/file", size: 0))])
        let folder = try unwrap(try await store.lookup(parentID: root, name: "Before"))
        let revision = try await store.volume().revision
        let events = try await store.events()
        await store.injectBeforeCommitFailureForTesting(true)
        await expect(.storage) { _ = try await store.rename(nodeID: folder.id, parentID: root, name: "After") }
        await store.injectBeforeCommitFailureForTesting(false)
        assertNotNil(try await store.lookup(parentID: root, name: "Before"))
        assertNil(try await store.lookup(parentID: root, name: "After"))
        assertEqual(try await store.volume().revision, revision)
        assertTrue(try await store.operations().isEmpty)
        assertEqual(try await store.events(), events)
        await store.close()
    }
    func testNamesCycleReplacementAndRootGuardsPreserveTree() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        try await store.importEntries([.init(path: "Résumé/Sub/file"), .init(path: "Other/item"), .init(path: "plain")])
        let folder = try unwrap(try await store.lookup(parentID: root, name: "Résumé"))
        let child = try unwrap(try await store.lookup(parentID: folder.id, name: "Sub"))
        await expect(.collision) { _ = try await store.create(parentID: root, name: "RÉSUMÉ", kind: .file) }
        await expect(.cycle) { _ = try await store.rename(nodeID: folder.id, parentID: child.id, name: "Recursive") }
        await expect(.rootProtected) { _ = try await store.rename(nodeID: root, parentID: child.id, name: "root") }
        await expect(.directoryNotEmpty) { _ = try await store.rename(nodeID: folder.id, parentID: root, name: "Other", replace: true) }
        await expect(.notDirectory) { _ = try await store.rename(nodeID: folder.id, parentID: root, name: "plain", replace: true) }
        for name in [".", "..", "", "bad/name", "a\u{0}b", String(repeating: "x", count: 256)] {
            await expect(.invalidName) { _ = try await store.create(parentID: root, name: name, kind: .file) }
        }
        let audio = try await store.create(parentID: child.id, name: "Adlib: Comp A.aif", kind: .file)
        assertEqual(try await store.resolvedPath(audio.id), "Résumé/Sub/Adlib: Comp A.aif")
        assertEqual(try await store.resolvedPath(child.id), "Résumé/Sub")
        let caseMove = try await store.rename(nodeID: folder.id, parentID: root, name: "RÉSUMÉ")
        assertEqual(caseMove.destinationPath, "RÉSUMÉ")
        await store.close()
    }
    func testGenerationFenceCannotClearNewerDirtySnapshot() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        try await store.importEntries([.init(path: "file", size: 4, backing: .init(key: "file", validator: "base", size: 4))])
        let file = try unwrap(try await store.lookup(parentID: root, name: "file"))
        let first = UUID(), second = UUID()
        let a = try await store.commitContent(nodeID: file.id, expectedGeneration: 0, newSize: 8, stagedSnapshotID: first)
        let opened = try await store.node(file.id)
        let b = try await store.commitContent(nodeID: file.id, expectedGeneration: 1, newSize: 12, stagedSnapshotID: second)
        assertEqual(a.targetGeneration, 1); assertEqual(b.targetGeneration, 2)
        assertEqual(opened.stagedSnapshotID, first)
        await expect(.generationChanged) { try await store.markContentPublished(nodeID: file.id, generation: 1, backing: .init(key: "published-old", size: 8)) }
        assertEqual(try await store.node(file.id).stagedSnapshotID, second)
        assertEqual(try await store.node(file.id).backing?.validator, "base")
        try await store.markContentPublished(nodeID: file.id, generation: 2, backing: .init(key: "published-new", validator: "new", size: 12))
        assertNil(try await store.node(file.id).stagedSnapshotID)
        assertEqual(try await store.node(file.id).backing?.key, "published-new")
        await store.close()
    }
    func testOperationReceiptsDependenciesAndPublishedRevisionAreDurable() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        var store: NamespaceStore? = try NamespaceStore(directory: directory, binding: "fixture")
        let root = try await store!.volume().rootID
        let node = try await store!.create(parentID: root, name: "A", kind: .directory)
        let first = try unwrap(try await store!.operations().first)
        let second = try await store!.rename(nodeID: node.id, parentID: root, name: "B")
        assertEqual(second.dependencies, [first.id])
        await expect(.invalidTransition) { try await store!.completeOperation(second.id) }
        try await store!.recordReceipt(operationID: first.id, stepID: "created", validator: "v1")
        await expect(.generationChanged) { try await store!.recordReceipt(operationID: first.id, stepID: "created", validator: "changed") }
        try await store!.completeOperation(first.id)
        try await store!.setOperationState(second.id, state: .running)
        try await store!.recordReceipt(operationID: second.id, stepID: "published", validator: "v2")
        await store!.close(); store = nil; store = try NamespaceStore(directory: directory, binding: "fixture")
        assertEqual(try await store!.receipts(operationID: second.id).count, 1)
        try await store!.completeOperation(second.id)
        assertTrue(try await store!.operations().isEmpty)
        assertEqual(try await store!.volume().publishedRevision, try await store!.volume().revision)
        await store!.close()
    }
    func testStoreOwnershipBindingAndReplacedDatabaseFailClosed() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture")
        XCTAssertThrowsError(try NamespaceStore(directory: directory, binding: "fixture"))
        await store.close()
        XCTAssertThrowsError(try NamespaceStore(directory: directory, binding: "other")) { assertEqual($0 as? NamespaceFailure, .bindingMismatch) }
        let reopened = try NamespaceStore(directory: directory, binding: "fixture")
        let original = directory.appendingPathComponent("namespace.sqlite")
        try FileManager.default.moveItem(at: original, to: directory.appendingPathComponent("retained.sqlite"))
        FileManager.default.createFile(atPath: original.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        await expect(.storage) { _ = try await reopened.volume() }
        await reopened.close()
    }
    func testManagedWALPreflightLeavesForeignDatabaseHeaderAndFilesUntouched() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "original", mode: .compatible)
        await store.close()
        let file = directory.appendingPathComponent("namespace.sqlite")
        let compatible = try Data(contentsOf: file)
        XCTAssertThrowsError(try NamespaceStore(directory: directory, binding: "different", mode: .managed)) {
            XCTAssertEqual($0 as? NamespaceFailure, .bindingMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: file), compatible)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let future = try Data(contentsOf: file)
        XCTAssertThrowsError(try NamespaceStore(directory: directory, binding: "original", mode: .managed)) {
            XCTAssertEqual($0 as? NamespaceFailure, .incompatibleSchema)
        }
        XCTAssertEqual(try Data(contentsOf: file), future)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-wal"))
    }
    func testForeignSchemaAndSymlinkStoreAreNeverRecreated() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"); await store.close()
        var db: OpaquePointer?; assertEqual(sqlite3_open(directory.appendingPathComponent("namespace.sqlite").path, &db), SQLITE_OK)
        assertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        XCTAssertThrowsError(try NamespaceStore(directory: directory, binding: "fixture")) { assertEqual($0 as? NamespaceFailure, .incompatibleSchema) }
        let link = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try NamespaceStore(directory: link, binding: "fixture"))
    }
    func testPagedListingAndTombstoneKeepOpenIdentityWithoutExposingRemovedTree() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        try await store.importEntries((0..<37).map { .init(path: "Folder/file-\($0)", size: 8, backing: .init(key: "Folder/file-\($0)", size: 8)) })
        let folder = try unwrap(try await store.lookup(parentID: root, name: "Folder"))
        var ids = Set<UUID>(), cursor: String?
        repeat {
            let page = try await store.list(parentID: folder.id, after: cursor, limit: 7)
            for n in page.nodes { assertTrue(ids.insert(n.id).inserted) }
            cursor = page.next
        } while cursor != nil
        assertEqual(ids.count, 37)
        let retained = try await store.node(try unwrap(ids.first))
        _ = try await store.remove(nodeID: folder.id, recursive: true)
        await expect(.notFound) { _ = try await store.node(retained.id) }
        assertEqual(try await store.retainedNode(retained.id).backing, retained.backing)
        assertNil(try await store.lookup(parentID: root, name: "Folder"))
        let replacement = try await store.create(parentID: root, name: "Folder", kind: .directory)
        assertNotEqual(replacement.id, folder.id); assertGreater(replacement.inode, retained.inode)
        await store.close()
    }
    func testSearchParentEventsAndMixedCaseDirectoryCookieFollowLogicalTree() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        try await store.importEntries([.init(path: "Album/Song One"), .init(path: "Album/Song Two"), .init(path: "Album/Else")])
        let album = try unwrap(try await store.lookup(parentID: root, name: "Album"))
        let page = try await store.list(parentID: album.id, limit: 1)
        let upper = try await store.list(parentID: album.id, after: page.next, limit: 1)
        let lower = try await store.list(parentID: album.id, after: page.next?.lowercased(), limit: 1)
        assertEqual(upper.nodes, lower.nodes)
        let operation = try await store.rename(nodeID: album.id, parentID: root, name: "Moved")
        assertEqual(operation.nodeSnapshot?.name, "Moved")
        assertTrue(operation.parentSnapshots?.contains(where: { $0.id == root && $0.metadataGeneration > 0 }) == true)
        let matches = try await store.search(text: "sOnG")
        assertEqual(matches.count, 2)
        for match in matches { assertTrue(try await store.resolvedPath(match.id).hasPrefix("Moved/")) }
        assertTrue(try await store.events().contains(where: { $0.nodeID == root && $0.kind == .metadata }))
        _ = try await store.remove(nodeID: album.id, recursive: true)
        assertTrue(try await store.search(text: "Song").isEmpty)
        await store.close()
    }
    func testHistoricalPublishedGenerationDoesNotClearNewerContentAndRelocationUsesCAS() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        try await store.importEntries([.init(path: "file", size: 4, backing: .init(key: "old", validator: "old", size: 4))])
        let file = try unwrap(try await store.lookup(parentID: root, name: "file"))
        _ = try await store.commitContent(nodeID: file.id, expectedGeneration: 0, newSize: 8, stagedSnapshotID: UUID())
        let secondSnapshot = UUID()
        _ = try await store.commitContent(nodeID: file.id, expectedGeneration: 1, newSize: 12, stagedSnapshotID: secondSnapshot)
        let firstBacking = ObjectLocator(key: "generation-1", validator: "v1", size: 8)
        try await store.recordPublishedContent(nodeID: file.id, generation: 1, backing: firstBacking)
        assertEqual(try await store.publishedLocator(nodeID: file.id, generation: 1), firstBacking)
        assertEqual(try await store.node(file.id).stagedSnapshotID, secondSnapshot)
        let currentBacking = ObjectLocator(key: "generation-2", validator: "v2", size: 12)
        try await store.recordPublishedContent(nodeID: file.id, generation: 2, backing: currentBacking)
        let relocated = ObjectLocator(key: "moved-generation-2", validator: "moved", size: 12)
        await expect(.generationChanged) { try await store.markContentRelocated(nodeID: file.id, generation: 2, expectedBacking: firstBacking, backing: relocated) }
        try await store.markContentRelocated(nodeID: file.id, generation: 2, expectedBacking: currentBacking, backing: relocated)
        assertEqual(try await store.node(file.id).backing, relocated)
        await store.close()
    }
    func testUnlinkedHandleWritesStayLocalAndRequestReplayDoesNotResurrectName() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        let createID = UUID(), file = try await store.create(parentID: root, name: "temporary", kind: .file, operationID: createID)
        let removal = try await store.remove(nodeID: file.id)
        await expect(.notFound) { _ = try await store.commitContent(nodeID: file.id, expectedGeneration: 0, newSize: 4, stagedSnapshotID: UUID()) }
        let writeID = UUID(), snapshot = UUID()
        let local = try await store.commitContent(nodeID: file.id, expectedGeneration: 0, newSize: 4, stagedSnapshotID: snapshot, operationID: writeID, allowUnlinked: true)
        assertEqual(local.localOnly, true); assertEqual(local.state, .complete)
        assertEqual(try await store.commitContent(nodeID: file.id, expectedGeneration: 0, newSize: 4, stagedSnapshotID: snapshot, operationID: writeID, allowUnlinked: true), local)
        assertEqual(try await store.retainedNode(file.id).stagedSnapshotID, snapshot)
        assertNil(try await store.lookup(parentID: root, name: "temporary"))
        assertEqual(try await store.create(parentID: root, name: "temporary", kind: .file, operationID: createID).id, file.id)
        assertNil(try await store.lookup(parentID: root, name: "temporary"))
        assertTrue(try await store.operations().allSatisfy { $0.id != local.id })
        assertEqual(try await store.receipts(operationID: local.id).first?.stepID, "local-unlinked-content")
        let replacement = try await store.create(parentID: root, name: "temporary", kind: .file)
        let next = try unwrap(try await store.operations().last)
        assertEqual(next.nodeID, replacement.id); assertEqual(next.dependencies, [removal.id])
        await expect(.invalidTransition) { try await store.setOperationState(next.id, state: .running) }
        await store.close()
    }
    func testManagedRestorePagesSurviveRestartWithoutExposingPartialTree() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let volumeID = UUID(), rootID = UUID(), folderID = UUID(), fileID = UUID()
        let root = NamespaceNode(id: rootID, inode: 2, parentID: nil, name: "", kind: .directory)
        let folder = NamespaceNode(id: folderID, inode: 20, parentID: rootID, name: "Restored", kind: .directory)
        let file = NamespaceNode(id: fileID, inode: 21, parentID: folderID, name: "file", kind: .file, size: 9, contentGeneration: 7, backing: .init(key: "immutable/content", validator: "version-7", size: 9))
        var store: NamespaceStore? = try NamespaceStore(directory: directory, binding: "fixture", mode: .managed, volumeID: volumeID, rootID: rootID)
        try await store!.beginManagedRestore(volumeID: volumeID, rootID: rootID, revision: 42)
        try await store!.stageManagedRestore([ManagedNodeRecord(node: file), ManagedNodeRecord(node: folder)])
        await expect(.invalidTransition) { _ = try await store!.list(parentID: rootID) }
        await expect(.invalidTransition) { _ = try await store!.create(parentID: rootID, name: "unsafe", kind: .file) }
        await store!.close(); store = nil
        store = try NamespaceStore(directory: directory, binding: "fixture", mode: .managed, volumeID: volumeID, rootID: rootID)
        assertEqual(try await store!.managedRestoreStatus()?.stagedRecords, 2)
        try await store!.stageManagedRestore([ManagedNodeRecord(node: root)])
        try await store!.finishManagedRestore()
        assertNil(try await store!.managedRestoreStatus())
        assertEqual(try await store!.volume().revision, 42)
        assertEqual(try await store!.volume().publishedRevision, 42)
        assertEqual(try await store!.node(fileID).contentGeneration, 7)
        assertEqual(try await store!.node(fileID).inode, 21)
        assertEqual(try await store!.node(folderID).inode, 20)
        assertEqual(try await store!.resolvedPath(fileID), "Restored/file")
        assertEqual(try await store!.publishedLocator(nodeID: fileID, generation: 7), file.backing)
        assertEqual(try await store!.node(inode: 2).id, rootID)
        var ids = Set<UUID>(), cursor: String?
        repeat { let page = try await store!.allNodes(after: cursor, limit: 1); for value in page.nodes { ids.insert(value.id) }; cursor = page.next } while cursor != nil
        assertEqual(ids, Set([rootID, folderID, fileID]))
        await expect(.invalidTransition) { try await store!.beginManagedRestore(volumeID: volumeID, rootID: rootID, revision: 43) }
        let future = try await store!.create(parentID: rootID, name: "future", kind: .file)
        assertGreater(future.inode, 21)
        await store!.close()
    }
    func testInvalidManagedRestoreRetainsStagingAndNeverExposesEmptySuccess() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let volumeID = UUID(), rootID = UUID()
        let store = try NamespaceStore(directory: directory, binding: "fixture", mode: .managed, volumeID: volumeID, rootID: rootID)
        let root = NamespaceNode(id: rootID, inode: 2, parentID: nil, name: "", kind: .directory)
        let orphan = NamespaceNode(id: UUID(), inode: 3, parentID: UUID(), name: "unreachable", kind: .file)
        try await store.beginManagedRestore(volumeID: volumeID, rootID: rootID, revision: 12)
        try await store.stageManagedRestore([.init(node: root), .init(node: orphan)])
        await expect(.corrupt) { try await store.finishManagedRestore() }
        assertEqual(try await store.managedRestoreStatus()?.stagedRecords, 2)
        await expect(.invalidTransition) { _ = try await store.list(parentID: rootID) }
        assertEqual(try await store.volume().revision, 0)
        await store.close()
    }
    func testAtomicSourceAdmissionNeverExposesEmptyPlaceholderAndReplaysWrite() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        let nodeID = UUID(), snapshotID = UUID(), requestID = UUID()
        await store.injectBeforeCommitFailureForTesting(true)
        await expect(.storage) { _ = try await store.createContent(parentID: root, name: "large.mov", nodeID: nodeID, snapshotID: snapshotID, size: 9_000_000_000, operationID: requestID) }
        await store.injectBeforeCommitFailureForTesting(false)
        assertNil(try await store.lookup(parentID: root, name: "large.mov"))
        assertTrue(try await store.operations().isEmpty)
        let created = try await store.createContent(parentID: root, name: "large.mov", nodeID: nodeID, snapshotID: snapshotID, size: 9_000_000_000, operationID: requestID)
        assertEqual(created.contentGeneration, 1); assertEqual(created.stagedSnapshotID, snapshotID); assertEqual(created.size, 9_000_000_000)
        let replayed = try await store.createContent(parentID: root, name: "large.mov", nodeID: nodeID, snapshotID: snapshotID, size: 9_000_000_000, operationID: requestID)
        assertEqual(created, replayed)
        let operation = try unwrap(try await store.operation(requestID))
        assertEqual(operation.kind, .write); assertEqual(operation.targetGeneration, 1)
        assertEqual(operation.nodeSnapshot?.size, 9_000_000_000)
        assertEqual(try await store.operations().count, 1)
        await store.close()
    }
    func testMetadataHistoryAndWriteRequestsKeepTheirAcceptedGeneration() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        let file = try await store.create(parentID: root, name: "File", kind: .file)
        let firstDate = Date(timeIntervalSince1970: 1234), secondDate = Date(timeIntervalSince1970: 5678), request = UUID()
        let first = try await store.updateMetadata(nodeID: file.id, modifiedAt: firstDate, operationID: request)
        _ = try await store.updateMetadata(nodeID: file.id, modifiedAt: secondDate)
        assertEqual(first.nodeSnapshot?.modifiedAt, firstDate)
        assertEqual(try await store.node(file.id).modifiedAt, secondDate)
        assertEqual(try await store.updateMetadata(nodeID: file.id, modifiedAt: firstDate, operationID: request), first)
        let writeID = UUID(), snapshot = UUID()
        let write = try await store.commitContent(nodeID: file.id, expectedGeneration: 0, newSize: 8, stagedSnapshotID: snapshot, operationID: writeID)
        _ = try await store.commitContent(nodeID: file.id, expectedGeneration: 1, newSize: 12, stagedSnapshotID: UUID())
        assertEqual(try await store.commitContent(nodeID: file.id, expectedGeneration: 0, newSize: 8, stagedSnapshotID: snapshot, operationID: writeID), write)
        assertEqual(write.nodeSnapshot?.contentGeneration, 1)
        assertEqual(try await store.node(file.id).contentGeneration, 2)
        await store.close()
    }
    func testAcceptedFolderRevisionRetainsChildrenAfterLaterLocalMovesAndWrites() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        try await store.importEntries([.init(path: "A/file", size: 4, backing: .init(key: "raw/A/file", validator: "base", size: 4)), .init(path: "Outside", kind: .directory)])
        let a = try unwrap(try await store.lookup(parentID: root, name: "A")), child = try unwrap(try await store.lookup(parentID: a.id, name: "file"))
        let outside = try unwrap(try await store.lookup(parentID: root, name: "Outside"))
        let move = try await store.rename(nodeID: a.id, parentID: root, name: "B")
        _ = try await store.rename(nodeID: child.id, parentID: outside.id, name: "later")
        let dirty = UUID(); _ = try await store.commitContent(nodeID: child.id, expectedGeneration: 0, newSize: 8, stagedSnapshotID: dirty)
        _ = try await store.create(parentID: a.id, name: "new-child", kind: .file)
        let acceptedChildren = try await store.listAsOf(parentID: a.id, revision: move.sequence)
        assertEqual(acceptedChildren.nodes.map(\.id), [child.id])
        assertEqual(acceptedChildren.nodes.first?.name, "file")
        assertEqual(acceptedChildren.nodes.first?.contentGeneration, 0)
        assertEqual(try await store.nodeAsOf(child.id, revision: move.sequence).parentID, a.id)
        assertEqual(try await store.node(child.id).parentID, outside.id)
        let relocated = ObjectLocator(key: "raw/B/file", validator: "copy", size: 4)
        try await store.markContentRelocated(nodeID: child.id, generation: 0, expectedBacking: try unwrap(child.backing), backing: relocated)
        assertEqual(try await store.node(child.id).stagedSnapshotID, dirty)
        assertEqual(try await store.publishedLocator(nodeID: child.id, generation: 0), relocated)
        assertEqual(try await store.node(child.id).backing, relocated)
        assertEqual(try await store.nodeAsOf(child.id, revision: move.sequence).backing, child.backing)
        await store.close()
    }
    func testHistoricalTombstoneAndReplacementDoNotRewriteEarlierDirectoryView() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        try await store.importEntries([.init(path: "Folder/one"), .init(path: "Folder/two")])
        let folder = try unwrap(try await store.lookup(parentID: root, name: "Folder"))
        let before = try await store.volume().revision
        let old = try await store.listAsOf(parentID: folder.id, revision: before)
        _ = try await store.remove(nodeID: folder.id, recursive: true)
        _ = try await store.create(parentID: root, name: "Folder", kind: .directory)
        assertEqual(try await store.listAsOf(parentID: folder.id, revision: before).nodes, old.nodes)
        await expect(.notFound) { _ = try await store.list(parentID: folder.id) }
        let rootAtBefore = try await store.listAsOf(parentID: root, revision: before)
        assertEqual(rootAtBefore.nodes.map(\.id), [folder.id])
        await store.close()
    }
    func testManagedImportDoesNotClaimCloudPublicationBeforeVerifiedRootReceipt() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture", mode: .managed)
        try await store.importEntries([.init(path: "original", size: 8, backing: .init(key: "raw/original", validator: "raw", size: 8))])
        let imported = try await store.volume()
        assertGreater(imported.revision, imported.publishedRevision)
        try await store.recordNamespacePublication(revision: imported.revision, validator: "verified-immutable-root")
        assertEqual(try await store.volume().publishedRevision, imported.revision)
        try await store.recordNamespacePublication(revision: imported.revision, validator: "verified-immutable-root")
        await expect(.generationChanged) { try await store.recordNamespacePublication(revision: imported.revision, validator: "unrelated-root") }
        _ = try await store.create(parentID: imported.rootID, name: "local", kind: .file)
        await expect(.invalidTransition) { try await store.recordNamespacePublication(revision: try await store.volume().revision, validator: "unconfirmed") }
        await store.close()
    }
    func testMoveOfHundredThousandDescendantsUpdatesBoundedRowsWithoutRewritingBacking() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "fixture"), root = try await store.volume().rootID
        for batch in 0..<100 {
            try await store.importEntries((0..<1000).map { offset in
                let index = batch * 1000 + offset
                return .init(path: "Tree/Sub/file-\(index)", size: 1, backing: .init(key: "raw/Tree/Sub/file-\(index)", size: 1))
            })
        }
        let tree = try unwrap(try await store.lookup(parentID: root, name: "Tree"))
        let sub = try unwrap(try await store.lookup(parentID: tree.id, name: "Sub"))
        let opened = try unwrap(try await store.lookup(parentID: sub.id, name: "file-99999"))
        let before = try await store.mutationCountForTesting()
        let start = ContinuousClock.now
        _ = try await store.rename(nodeID: tree.id, parentID: root, name: "Moved")
        let elapsed = start.duration(to: .now)
        let after = try await store.mutationCountForTesting()
        assertLessOrEqual(after - before, 32)
        assertEqual(try await store.nodeCountForTesting(), 100_003)
        assertEqual(try await store.resolvedPath(opened.id), "Moved/Sub/file-99999")
        assertEqual(try await store.node(opened.id).inode, opened.inode)
        assertEqual(try await store.resolvedLocator(opened.id)?.key, "raw/Tree/Sub/file-99999")
        print("NAMESPACE_100000_RENAME elapsed=\(elapsed) sqlite_changed_rows=\(after-before)")
        await store.close()
    }
}

extension NamespaceStore {
    func seedSummaryRowsForTesting() throws {
        // Opaque payloads make accidental full-journal decoding fail.
        try database.exec("""
            WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<10005)
            INSERT INTO operations(id,sequence,node,kind,state,error,payload)
            SELECT printf('%032x',n),n,(SELECT root FROM volume),'metadata',
              CASE WHEN n<=3 THEN 'attention' WHEN n=4 THEN 'complete' ELSE 'pending' END,
              CASE WHEN n=1 THEN 'offline' WHEN n=3 THEN 'conflict' ELSE NULL END,X'00' FROM numbers
            """)
    }
    func injectBeforeCommitFailureForTesting(_ enabled: Bool) {
        database.beforeCommitForTesting = enabled ? { throw NamespaceFailure.storage } : nil
    }
    func mutationCountForTesting() throws -> Int { try database.validate(); return Int(sqlite3_total_changes(database.db)) }
    func nodeCountForTesting() throws -> Int { try database.validate(); return Int(try database.scalar("SELECT count(*) FROM nodes")) }
}
