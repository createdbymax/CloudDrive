import XCTest
import SQLite3
@testable import CloudDrive

private func object(_ name: String, size: Int64 = 42) -> CatalogObject {
    CatalogObject(key: "prefix/" + name, size: size, modified: Date(timeIntervalSince1970: 1_700_000_000), etag: "\"opaque-tag\"")
}

actor FixtureInventory: ObjectInventoryRemote {
    var pages: [String: InventoryPage]
    var missing: Set<String>
    var failToken: String?
    var headFails: Bool
    private(set) var requested: [String] = []
    private(set) var heads: [String] = []
    init(pages: [String: InventoryPage], missing: Set<String> = [], failToken: String? = nil, headFails: Bool = false) {
        self.pages = pages; self.missing = missing; self.failToken = failToken; self.headFails = headFails
    }
    func list(token: String?) async throws -> InventoryPage {
        requested.append(token ?? "")
        if token == failToken && failToken != nil { throw CatalogFailure.http(503) }
        guard let page = pages[token ?? ""] else { throw CatalogFailure.invalidInventory }
        return page
    }
    func isMissing(key: String) async throws -> Bool {
        heads.append(key)
        if headFails { throw CatalogFailure.http(403) }
        return missing.contains(key)
    }
}

final class CatalogTests: XCTestCase {
    private var directory: URL!
    private var store: CatalogStore!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-" + UUID().uuidString)
        store = CatalogStore(directory: directory, fingerprint: "fixture", prefix: "prefix")
    }
    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func seed(_ objects: [CatalogObject]) async throws {
        let remote = FixtureInventory(pages: ["": InventoryPage(objects: objects, nextToken: nil)])
        try await CatalogIndexer.scan(store: store, remote: remote, fresh: true)
    }
    func testPersistentInventoryOfflinePrefixSearchAndFilters() async throws {
        try await seed([object("Album/Vócals Final.wav", size: 2_000_000_000), object("Album/drums.wav"), object("video.mov")])
        var summary = try await store.summary()
        XCTAssertEqual(summary.count, 3); XCTAssertNotNil(summary.lastCompleted); XCTAssertFalse(summary.hasPartialScan)
        store = nil
        store = CatalogStore(directory: directory, fingerprint: "fixture", prefix: "prefix")
        // CatalogStore cannot access a remote or mount: this search is offline by construction.
        let matches = try await store.search(CatalogQuery(text: "VOC final", fileExtension: ".wav", minimumSize: 1_000_000_000))
        XCTAssertEqual(matches.map(\.key), ["prefix/Album/Vócals Final.wav"])
        let path = try await store.search(CatalogQuery(text: "album"))
        XCTAssertEqual(path.count, 2)
        let noMatch = try await store.search(CatalogQuery(text: "voc", fileExtension: "mov"))
        XCTAssertTrue(noMatch.isEmpty)
        summary = try await store.summary(); XCTAssertEqual(summary.count, 3)
    }
    func testInterruptedScanPersistsTokenAndDoesNotDeleteOldRows() async throws {
        try await seed([object("old.wav")])
        let interrupted = FixtureInventory(pages: ["": InventoryPage(objects: [object("new.wav")], nextToken: "page+2/%")], failToken: "page+2/%")
        do { try await CatalogIndexer.scan(store: store, remote: interrupted, fresh: true); XCTFail("Must fail") } catch {}
        let partial = try await store.summary(); XCTAssertEqual(partial.count, 2); XCTAssertTrue(partial.hasPartialScan)
        store = nil; store = CatalogStore(directory: directory, fingerprint: "fixture", prefix: "prefix")
        let resumed = FixtureInventory(pages: ["page+2/%": InventoryPage(objects: [object("last.wav")], nextToken: nil)])
        try await CatalogIndexer.scan(store: store, remote: resumed, fresh: false)
        let tokens = await resumed.requested; XCTAssertEqual(tokens, ["page+2/%"])
        let final = try await store.summary(); XCTAssertEqual(final.count, 3); XCTAssertFalse(final.hasPartialScan)
    }
    func testOnlyConfirmedMissingIsRemovedAndFTSIsUpdated() async throws {
        try await seed([object("gone.wav"), object("retained.wav")])
        let remote = FixtureInventory(pages: ["": InventoryPage(objects: [], nextToken: nil)], missing: ["prefix/gone.wav"])
        try await CatalogIndexer.scan(store: store, remote: remote, fresh: true)
        let matches = try await store.search(CatalogQuery(text: "gone")); XCTAssertTrue(matches.isEmpty)
        let summary = try await store.summary(); XCTAssertEqual(summary.count, 1)
        try await seed([object("gone.wav", size: 100)])
        let resurrected = try await store.search(CatalogQuery(text: "gone")); XCTAssertEqual(resurrected.first?.size, 100)
    }
    func testHeadPermissionFailurePreservesMissingObjectsAndFreshness() async throws {
        try await seed([object("private.wav")])
        let before = try await store.summary()
        let remote = FixtureInventory(pages: ["": InventoryPage(objects: [], nextToken: nil)], headFails: true)
        do { try await CatalogIndexer.scan(store: store, remote: remote, fresh: true); XCTFail("Must not treat 403 as absence") } catch {}
        let after = try await store.summary(); XCTAssertEqual(after.count, 1); XCTAssertEqual(after.lastCompleted, before.lastCompleted); XCTAssertTrue(after.hasPartialScan)
    }
    func testRepeatedTokenRollsBackEntirePageAndCanStartFresh() async throws {
        let scan = try await store.beginScan(fresh: true)
        try await store.commit(page: InventoryPage(objects: [object("first")], nextToken: "same"), scan: scan)
        do {
            try await store.commit(page: InventoryPage(objects: [object("uncommitted")], nextToken: "same"), scan: CatalogScan(id: scan.id, token: "same"))
            XCTFail("Cycle must fail")
        } catch {}
        let rows = try await store.search(CatalogQuery(text: "uncommitted")); XCTAssertTrue(rows.isEmpty)
        let resumed = try await store.beginScan(fresh: false); XCTAssertEqual(resumed.token, "same")
        let fresh = try await store.beginScan(fresh: true); XCTAssertNil(fresh.token); XCTAssertNotEqual(fresh.id, scan.id)
        do { try await store.commit(page: InventoryPage(objects: [], nextToken: nil), scan: scan); XCTFail("Stale generation") } catch {}
    }
    func testMidPageDatabaseFailureRollsBackRowsFTSAndToken() async throws {
        try await seed([object("original.wav")])
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("catalog.sqlite").path,&connection),SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TRIGGER fixture_failure BEFORE INSERT ON objects WHEN new.name='fail.wav' BEGIN SELECT RAISE(ABORT,'fixture'); END;",nil,nil,nil),SQLITE_OK)
        let scan = try await store.beginScan(fresh:true)
        do {
            try await store.commit(page:InventoryPage(objects:[object("uncommitted.wav"),object("fail.wav")],nextToken:"next"),scan:scan)
            XCTFail("Second row must fail")
        } catch {}
        let rows = try await store.search(CatalogQuery(text:"uncommitted")); XCTAssertTrue(rows.isEmpty)
        let summary = try await store.summary(); XCTAssertEqual(summary.count,1)
        let resumed = try await store.beginScan(fresh:false); XCTAssertNil(resumed.token)
        let original = try await store.search(CatalogQuery(text:"original")); XCTAssertEqual(original.count,1)
    }
    func testDestinationBindingAndExclusiveOwnership() async throws {
        _ = try await store.summary()
        let second = CatalogStore(directory: directory, fingerprint: "fixture", prefix: "prefix")
        do { _ = try await second.summary(); XCTFail("Must reject a second owner") } catch {}
        store = nil
        let wrong = CatalogStore(directory: directory, fingerprint: "other", prefix: "prefix")
        do { _ = try await wrong.summary(); XCTFail("Must reject another destination") } catch {}
    }
    func testExactByteIdentityPreservesCanonicalUnicodeAndCaseVariants() async throws {
        let names = ["Café.wav", "Cafe\u{301}.wav", "CAFE.wav", "cafe.wav", "literal%2F+a.wav", "folder/../unsafe.wav"]
        try await seed(names.map { object($0) })
        let summary = try await store.summary(); XCTAssertEqual(summary.count, names.count)
        let matches = try await store.search(CatalogQuery(text: "cafe")); XCTAssertEqual(Set(matches.map(\.id)).count, 4)
        XCTAssertNil(CatalogText.mountURL(key: "prefix/folder/../unsafe.wav", prefix: "prefix", mount: directory))
        let safe = CatalogText.mountURL(key: "prefix/literal%2F+a.wav", prefix: "prefix", mount: directory)
        XCTAssertEqual(safe?.lastPathComponent, "literal%2F+a.wav")
    }
    func testInvalidPageCannotPartiallyCommit() async throws {
        let scan = try await store.beginScan(fresh: true)
        let invalid = CatalogObject(key: "prefix-neighbor/private", size: 1, modified: Date(), etag: "tag")
        do { try await store.commit(page: InventoryPage(objects: [object("good"), invalid], nextToken: "next"), scan: scan); XCTFail("Scope escape") } catch {}
        let summary = try await store.summary(); XCTAssertEqual(summary.count, 0)
        let resumed = try await store.beginScan(fresh: false); XCTAssertNil(resumed.token)
    }
    func testSearchSyntaxCannotInjectSQLOrFTSOperators() async throws {
        try await seed([object("alpha.wav"), object("beta.wav")])
        for text in ["alpha OR beta", "alpha' UNION SELECT", "alpha NEAR beta", "\"alpha\" AND beta"] {
            let result = try await store.search(CatalogQuery(text: text)); XCTAssertTrue(result.isEmpty, text)
        }
        do { _ = try await store.search(CatalogQuery(text: String(repeating: "a", count: 257))); XCTFail("Unbounded query") } catch {}
        do { _ = try await store.search(CatalogQuery(text: "***")); XCTFail("Not searchable") } catch {}
        let combining = "a" + String(repeating: "\u{301}", count: 3000)
        XCTAssertThrowsError(try CatalogQuery(text: combining).terms())
        let short = try await store.search(CatalogQuery(text: "a")); XCTAssertEqual(short.count, 1)
    }
    func testCancellationAndSearchDuringBulkScan() async throws {
        let scan = try await store.beginScan(fresh: true)
        try await store.commit(page: InventoryPage(objects: [object("vocals.wav")], nextToken: "next"), scan: scan)
        let query = Task { try await store.search(CatalogQuery(text: "voc")) }; query.cancel()
        do { _ = try await query.value; XCTFail("Must cancel") } catch is CancellationError {} catch { XCTFail("Wrong cancellation: \(error)") }
        let valid = try await store.search(CatalogQuery(text: "voc")); XCTAssertEqual(valid.count, 1)
    }
    func testMassMissingCircuitBreakerRetainsInventory() async throws {
        try await seed((0..<200).map { object("file\($0).wav") })
        let remote = FixtureInventory(pages: ["": InventoryPage(objects: [], nextToken: nil)], missing: Set((0..<200).map { "prefix/file\($0).wav" }))
        do { try await CatalogIndexer.scan(store: store, remote: remote, fresh: true); XCTFail("Must preserve mass absence") } catch {}
        let summary = try await store.summary(); XCTAssertEqual(summary.count, 200)
        let heads = await remote.heads; XCTAssertTrue(heads.isEmpty)
    }
    func testSymlinkAndCorruptionAreRejectedWithoutTouchingTarget() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("keep me".utf8).write(to: target); defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("catalog.sqlite"), withDestinationURL: target)
        do { _ = try await store.summary(); XCTFail("Symlink") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), Data("keep me".utf8))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("catalog.sqlite"))
        try Data("not a database".utf8).write(to: directory.appendingPathComponent("catalog.sqlite"))
        do { _ = try await store.summary(); XCTFail("Corrupt") } catch {}
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("catalog.sqlite")), Data("not a database".utf8))
    }
    func testLowSpaceRollsBackPageWithoutLosingSavedData() async throws {
        try await seed([object("saved.wav")])
        store = nil
        store = CatalogStore(directory: directory, fingerprint: "fixture", prefix: "prefix", minimumFreeBytes: Int64.max)
        let scan = try await store.beginScan(fresh: true)
        do { try await store.commit(page: InventoryPage(objects: [object("new.wav")], nextToken: nil), scan: scan); XCTFail("Low space") }
        catch CatalogFailure.diskSpace {} catch { XCTFail("Wrong error: \(error)") }
        let rows = try await store.search(CatalogQuery(text: "saved")); XCTAssertEqual(rows.count, 1)
        let summary = try await store.summary(); XCTAssertEqual(summary.count, 1)
    }
    func testDirectoryReplacementRejectsFurtherOperations() async throws {
        try await seed([object("saved.wav")])
        let moved = directory.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { _ = try await store.search(CatalogQuery(text: "saved")); XCTFail("Replaced directory") } catch {}
    }
    func testScaleQueriesAndOfflineRestore() async throws {
        let count = Int(ProcessInfo.processInfo.environment["CLOUDDRIVE_CATALOG_SCALE"] ?? "10000") ?? 10_000
        var scan = try await store.beginScan(fresh: true)
        let start = Date()
        for base in stride(from: 0, to: count, by: 1000) {
            let end = min(base+1000,count)
            let objects = (base..<end).map { object("Project\($0 % 97)/vocals_take_\($0).wav", size: Int64($0)*1000) }
            let token = end < count ? "page-\(end)" : nil
            try await store.commit(page: InventoryPage(objects: objects, nextToken: token), scan: scan)
            // Search remains usable between page transactions.
            let rows = try await store.search(CatalogQuery(text: "vocals", limit: 50)); XCTAssertEqual(rows.count, 50)
            scan = CatalogScan(id: scan.id, token: token)
        }
        try await store.finish(scanID: scan.id)
        let indexed = Date().timeIntervalSince(start)
        var samples: [Double] = []
        for query in ["vocals", "project7", "take", "definitelyabsent", "vocals 987", "v"] {
            for _ in 0..<10 {
                let begin = Date(); _ = try await store.search(CatalogQuery(text: query)); samples.append(Date().timeIntervalSince(begin))
            }
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count-1)*0.95)]
        print("CATALOG_BENCHMARK objects=\(count) index_seconds=\(indexed) query_p95_ms=\(p95*1000) query_max_ms=\(samples.last!*1000) sqlite=\(String(cString:sqlite3_libversion()))")
        XCTAssertLessThan(p95,0.15)
        let summary = try await store.summary(); XCTAssertEqual(summary.count, count)
    }
}
