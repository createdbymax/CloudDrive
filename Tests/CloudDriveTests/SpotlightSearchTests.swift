import XCTest
@testable import CloudDrive

@MainActor final class SpotlightSearchTests: XCTestCase {
    private func item(_ name: String) -> CatalogObject {
        CatalogObject(key: "prefix/" + name, size: 42, modified: Date(timeIntervalSince1970: 1_700_000_000), etag: "fixture")
    }

    func testLateQueryCannotReplaceNewResultsOrSelection() async throws {
        let oldResult = item("old.wav"), newResult = item("new.wav")
        var pending: CheckedContinuation<[CatalogObject], Never>?
        let model = SpotlightSearchModel(debounce: .zero) { query in
            if query.text == "old" { return await withCheckedContinuation { pending = $0 } }
            return [newResult]
        }
        model.query = "old"
        let first = Task { await model.search() }
        let deadline = Date().addingTimeInterval(2)
        while pending == nil, Date() < deadline { await Task.yield() }
        guard let pending else { first.cancel(); return XCTFail("First query did not start") }
        model.query = "new"
        await model.search()
        XCTAssertEqual(model.results, [newResult])
        pending.resume(returning: [oldResult])
        await first.value
        XCTAssertEqual(model.results, [newResult])
        XCTAssertEqual(model.selectedResult, newResult)
        XCTAssertFalse(model.searching)
    }

    func testEditingAndResetInvalidateSelectableResults() async {
        let result = item("Vocals.wav")
        let model = SpotlightSearchModel(debounce: .zero) { _ in [result] }
        await model.search()
        XCTAssertEqual(model.selectedResult, result)
        model.query = "drums"
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedResult)
        await model.search()
        model.reset()
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedResult)
    }

    func testNavigationWrapsAndErrorsClearSelection() async {
        let results = [item("one.wav"), item("two.wav"), item("three.wav")]
        let model = SpotlightSearchModel(debounce: .zero) { query in
            if query.text == "invalid" { throw CatalogFailure.query }
            return results
        }
        await model.search()
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedResult, results[2])
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedResult, results[0])
        model.query = "invalid"
        await model.search()
        XCTAssertFalse(model.error.isEmpty)
        XCTAssertNil(model.selectedResult)
        XCTAssertFalse(model.searching)
    }

    func testRefreshRetainsIdentityAcrossRenameAndReorderThenChoosesNearestRow() async {
        let node = UUID()
        var old = item("original.wav"); old.nodeID = node
        var moved = item("new-folder/renamed.wav"); moved.nodeID = node
        let other = item("other.wav"), last = item("last.wav")
        var snapshot = [other, old, last]
        let model = SpotlightSearchModel(debounce: .zero) { _ in snapshot }
        await model.search(scope: "drive-one")
        model.selectedID = old.id
        snapshot = [moved, other, last]
        await model.search(scope: "drive-one")
        XCTAssertEqual(model.selectedResult, moved)
        XCTAssertEqual(old.id, moved.id)
        snapshot = [other, last]
        await model.search(scope: "drive-one")
        XCTAssertEqual(model.selectedResult, other)
        model.selectedID = last.id
        snapshot = [other]
        await model.search(scope: "drive-one")
        XCTAssertEqual(model.selectedResult, other)
    }
    func testRefreshDoesNotStealSelectionChangedWhileResultsAreLoading() async throws {
        let first = item("first.wav"), second = item("second.wav")
        var continuation: CheckedContinuation<[CatalogObject], Never>?
        var wait = false
        let model = SpotlightSearchModel(debounce: .zero) { _ in
            if wait { return await withCheckedContinuation { continuation = $0 } }
            return [first, second]
        }
        await model.search(scope: "a")
        wait = true
        let refresh = Task { await model.search(scope: "a") }
        let deadline = Date().addingTimeInterval(2)
        while continuation == nil, Date() < deadline { await Task.yield() }
        guard let continuation else { refresh.cancel(); return XCTFail("Refresh did not start") }
        XCTAssertEqual(model.results, [first, second])
        model.selectedID = second.id
        continuation.resume(returning: [second, first]); await refresh.value
        XCTAssertEqual(model.selectedResult, second)
        wait = false
        await model.search(scope: "b")
        XCTAssertEqual(model.selectedResult, first)
    }
    func testOfflineAvailabilityRequiresFreshVerifiedSampleAndDoesNotChangeIdentity() {
        let checked = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(CatalogAvailability.effective(nil, checkedAt: checked, at: checked))
        XCTAssertEqual(CatalogAvailability.effective(.availableOffline, checkedAt: nil, at: checked), .unknown)
        XCTAssertEqual(CatalogAvailability.effective(.availableOffline, checkedAt: checked, at: checked.addingTimeInterval(4)), .availableOffline)
        XCTAssertEqual(CatalogAvailability.effective(.availableOffline, checkedAt: checked, at: checked.addingTimeInterval(6)), .unknown)
        XCTAssertEqual(CatalogAvailability.effective(.availableOffline, checkedAt: checked, at: checked.addingTimeInterval(-1)), .unknown)
        var value = item("cached.wav"); value.nodeID = UUID()
        let identity = value.id
        value.availability = .downloading; value.availabilityCheckedAt = checked
        XCTAssertEqual(value.id, identity)
        value.availability = .availableOffline
        XCTAssertEqual(value.id, identity)
        XCTAssertNotEqual(CatalogAvailability.remoteOnly.label, CatalogAvailability.availableOffline.label)
    }
    func testNamespaceUploadRateReadbackUsesNativeUnlimitedRepresentation() {
        XCTAssertEqual(UploadLimit.namespaceLabel(nil), "Unknown")
        XCTAssertEqual(UploadLimit.namespaceLabel(-1), "Unknown")
        XCTAssertEqual(UploadLimit.namespaceLabel(0), "Unlimited")
        XCTAssertEqual(UploadLimit.namespaceLabel(625_000), "5 Mbps")
        XCTAssertEqual(UploadLimit.namespaceLabel(2_500_000), "20 Mbps")
    }
    func testObjectETagThatLooksLikeUUIDDoesNotBecomeNamespaceIdentity() {
        let value = UUID().uuidString
        let first = CatalogObject(key: "prefix/first", size: 0, modified: Date(), etag: value)
        let second = CatalogObject(key: "prefix/second", size: 0, modified: Date(), etag: value)
        XCTAssertNotEqual(first.id, second.id)
    }
    func testPanelSnapshotSearchPreservesInventoryWindowResultsOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-isolation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = Connection(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "prefix", accessKey: "fixture", secretKey: "fixture")
        var store: CatalogStore? = CatalogStore(directory: root.appendingPathComponent("Catalog/" + connection.fingerprint), fingerprint: connection.fingerprint, prefix: connection.prefix)
        let scan = try await store!.beginScan(fresh: true)
        let vocals = item("Vocals.wav"), drums = item("Drums.wav")
        try await store!.commit(page: InventoryPage(objects: [vocals, drums], nextToken: nil), scan: scan)
        try await store!.finish(scanID: scan.id)
        store = nil
        let catalog = CatalogController(root: root, makeRemote: { _ in fatalError("Search must never create a remote") })
        catalog.configure(connection: connection)
        _ = try await catalog.searchSnapshot(CatalogQuery(text: ""))
        await catalog.search(CatalogQuery(text: "voc"))
        let model = SpotlightSearchModel(catalog: catalog)
        model.query = "dru"
        await model.search()
        XCTAssertEqual(model.results, [drums])
        XCTAssertEqual(catalog.results, [vocals])
        XCTAssertTrue(catalog.searchError.isEmpty)
        XCTAssertFalse(catalog.searching)
    }
}
