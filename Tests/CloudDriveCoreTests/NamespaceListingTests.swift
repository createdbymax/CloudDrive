import XCTest
@testable import CloudDriveCore

final class NamespaceListingTests: XCTestCase {
    func testPaginatedDeepDirectoryPreservesCompleteNodesAndSkipsDeletedChildren() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "listing", mode: .managed)
        let root = try await store.volume().rootID
        let path = "one/two/three/four"
        try await store.importEntries((0..<67).map {
            NamespaceImportEntry(path: "\(path)/remote-\($0)", size: Int64($0), backing: .init(key: "remote/\($0)", validator: "v\($0)", size: Int64($0)))
        })
        var parent = root
        for name in path.split(separator: "/") {
            let found = try await store.lookup(parentID: parent, name: String(name))
            parent = try XCTUnwrap(found).id
        }
        let snapshot = UUID()
        let staged = try await store.createContent(parentID: parent, name: "staged", nodeID: UUID(), snapshotID: snapshot, size: 12345, nativeXattrs: true)
        _ = try await store.setXattr(nodeID: staged.id, name: "com.apple.provenance", value: Data([0, 1, 255]), policy: "set", operationID: UUID())
        let modified = Date(timeIntervalSince1970: 1234567890.125)
        _ = try await store.updateMetadata(nodeID: staged.id, modifiedAt: modified)
        let removed = try await store.lookup(parentID: parent, name: "remote-17")
        _ = try await store.remove(nodeID: XCTUnwrap(removed).id)
        let revision = try await store.volume().revision
        var cursor: String?, collected: [NamespaceNode] = [], pages = 0
        repeat {
            let page = try await store.list(parentID: parent, after: cursor, limit: 7, includeDotInodes: true)
            XCTAssertEqual(page.revision, revision)
            XCTAssertNotNil(page.dotInodes)
            XCTAssertLessThanOrEqual(page.nodes.count, 7)
            for entry in page.nodes {
                let authoritative = try await store.node(entry.id)
                XCTAssertEqual(entry, authoritative)
            }
            collected += page.nodes; cursor = page.next; pages += 1
        } while cursor != nil
        XCTAssertEqual(pages, 10)
        XCTAssertEqual(collected.count, 67)
        XCTAssertEqual(Set(collected.map(\.id)).count, 67)
        XCTAssertEqual(collected.map { $0.id.uuidString }, collected.map { $0.id.uuidString }.sorted())
        XCTAssertFalse(collected.contains { $0.id == removed?.id })
        let listed = try XCTUnwrap(collected.first { $0.id == staged.id })
        XCTAssertEqual(listed.stagedSnapshotID, snapshot)
        XCTAssertEqual(listed.size, 12345)
        XCTAssertEqual(listed.modifiedAt, modified)
        XCTAssertEqual(listed.xattrs, ["com.apple.provenance": Data([0, 1, 255])])
        XCTAssertNil(listed.backing)
        XCTAssertTrue(collected.contains { $0.backing?.validator == "v42" })
        await store.close()
    }

    func testListingCannotExposeDescendantsOfTombstonedAncestor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NamespaceStore(directory: directory, binding: "hidden-listing")
        let root = try await store.volume().rootID
        try await store.importEntries([.init(path: "outer/inner/file")])
        let outerResult = try await store.lookup(parentID: root, name: "outer")
        let outer = try XCTUnwrap(outerResult)
        let innerResult = try await store.lookup(parentID: outer.id, name: "inner")
        let inner = try XCTUnwrap(innerResult)
        _ = try await store.remove(nodeID: outer.id, recursive: true)
        do {
            _ = try await store.list(parentID: inner.id)
            XCTFail("A retained descendant must remain hidden")
        } catch { XCTAssertEqual(error as? NamespaceFailure, .notFound) }
        let page = try await store.list(parentID: root, limit: 1, includeDotInodes: true)
        XCTAssertTrue(page.nodes.isEmpty)
        XCTAssertNil(page.next)
        XCTAssertEqual(page.dotInodes?.directory, page.dotInodes?.parent)
        await store.close()
    }
}
