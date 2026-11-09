import XCTest
import SQLite3
@testable import CloudDrive

private let automaticConnection = Connection(endpoint:"https://automatic-fixture.r2.cloudflarestorage.com",bucket:"fixture",prefix:"prefix",accessKey:"synthetic-access",secretKey:"synthetic-secret")
private func entry(_ key: String, size: Int64 = 42) -> CatalogObject {
    CatalogObject(key:key,size:size,modified:Date(timeIntervalSince1970:1_700_000_000),etag:"opaque")
}

actor MutableCatalogRemote: ObjectInventoryRemote {
    private var objects: [Data:CatalogObject] = [:]
    private var failures = Set<Data>()
    private(set) var heads = 0
    private(set) var lists = 0
    func put(_ object: CatalogObject) { objects[object.id] = object }
    func remove(_ key: String) { objects.removeValue(forKey:Data(key.utf8)) }
    func deny(_ key: String) { failures.insert(Data(key.utf8)) }
    func allow(_ key: String) { failures.remove(Data(key.utf8)) }
    func list(token: String?) async throws -> InventoryPage { try await list(scope:"prefix/",token:token) }
    func list(scope: String, token: String?) async throws -> InventoryPage {
        lists += 1
        return InventoryPage(objects:objects.values.filter { $0.key.utf8.starts(with:scope.utf8) }.sorted { $0.key < $1.key },nextToken:nil)
    }
    func head(key: String) async throws -> CatalogObject? {
        heads += 1
        if failures.contains(Data(key.utf8)) { throw CatalogFailure.http(403) }
        return objects[Data(key.utf8)]
    }
    func isMissing(key: String) async throws -> Bool { try await head(key:key) == nil }
}

final class AutomaticCatalogTests: XCTestCase {
    private var root: URL!
    private var store: CatalogStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-auto-" + UUID().uuidString)
        store = CatalogStore(directory:root.appendingPathComponent("catalog"),fingerprint:automaticConnection.fingerprint,prefix:"prefix")
    }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    private func hint(_ key: String) -> UploadCatalogHint { UploadCatalogHint(id:UUID().uuidString,destination:automaticConnection.fingerprint,key:key) }
    private func feed(session: String = "worker-one", first: Int64 = 1, latest: Int64, next: Int64, gap: Bool = false, events: [(Int64,String,Bool)]) -> WorkerMetadataChanges {
        WorkerMetadataChanges(version:1,session:session,first:first,latest:latest,events:events.map { .init(sequence:$0.0,path:$0.1,recursive:$0.2) },next:next,hasMore:next<latest,gap:gap)
    }
    private func uploadJob() throws -> DirectUploadJob {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("empty.wav"); try Data().write(to:file)
        return DirectUploadJob(batchID:UUID(),sourcePath:file.path,source:try UploadSourceIdentity.capture(file),destination:automaticConnection.fingerprint,key:"prefix/empty.wav",partSize:5*1_048_576)
    }
    func testUploadOutboxSurvivesHistoryClearRestartAndLostAcknowledgement() async throws {
        let job = try uploadJob(), records = root.appendingPathComponent("records")
        var queue: UploadQueueStore? = try UploadQueueStore(directory:records)
        try queue!.insert([job])
        XCTAssertTrue(try queue!.pendingCatalogHints(destination:automaticConnection.fingerprint).isEmpty)
        var completed = job; completed.status = .uploaded; completed.phase = .complete; completed.verifiedAt = Date()
        try queue!.save(completed)
        let hints = try queue!.pendingCatalogHints(destination:automaticConnection.fingerprint); XCTAssertEqual(hints.count,1)
        try storeCheckAndDropHistory(queue:queue!,hints:hints)
        queue = nil; queue = try UploadQueueStore(directory:records)
        XCTAssertTrue(try queue!.load().isEmpty)
        XCTAssertEqual(try queue!.pendingCatalogHints(destination:automaticConnection.fingerprint),hints)
        try await store.recordUploadHints(hints)
        // Simulate a crash after durable catalog delivery but before source acknowledgement.
        try await store.recordUploadHints(hints)
        let pending = try await store.pendingChanges(); XCTAssertEqual(pending.count,1)
        try queue!.acknowledgeCatalogHints(hints)
        XCTAssertTrue(try queue!.pendingCatalogHints(destination:automaticConnection.fingerprint).isEmpty)
        queue = nil
    }
    private func storeCheckAndDropHistory(queue: UploadQueueStore,hints:[UploadCatalogHint]) throws {
        try queue.removeFinished()
        XCTAssertEqual(try queue.pendingCatalogHints(destination:automaticConnection.fingerprint),hints)
    }
    func testUploadReceiptAndOutboxAreAtomicWhenHintWriteFails() throws {
        let job = try uploadJob(), records = root.appendingPathComponent("records")
        let queue = try UploadQueueStore(directory:records); try queue.insert([job])
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(records.appendingPathComponent("uploads.sqlite").path,&connection),SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TRIGGER hint_fail BEFORE INSERT ON catalog_outbox BEGIN SELECT RAISE(ABORT,'fixture'); END;",nil,nil,nil),SQLITE_OK)
        var completed = job; completed.status = .uploaded; completed.phase = .complete; completed.verifiedAt = Date()
        XCTAssertThrowsError(try queue.save(completed))
        XCTAssertEqual(try queue.load().first?.status,.waiting)
        XCTAssertTrue(try queue.pendingCatalogHints(destination:automaticConnection.fingerprint).isEmpty)
    }
    func testAcknowledgedHintsAreNotRecreatedByLegacyBackfill() throws {
        var job = try uploadJob(); job.status = .uploaded; job.phase = .complete; job.verifiedAt = Date()
        let queue = try UploadQueueStore(directory:root.appendingPathComponent("records")); try queue.insert([job])
        let hints = try queue.pendingCatalogHints(destination:automaticConnection.fingerprint)
        try queue.acknowledgeCatalogHints(hints)
        try queue.backfillCatalogHints(try queue.load())
        XCTAssertTrue(try queue.pendingCatalogHints(destination:automaticConnection.fingerprint).isEmpty)
        XCTAssertTrue(try queue.pendingCatalogHints(destination:"foreign").isEmpty)
    }
    func testVersionOneCatalogMigratesWithoutLosingSearchData() async throws {
        let directory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var old: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("catalog.sqlite").path,&old),SQLITE_OK)
        let schema = """
        CREATE TABLE meta(fingerprint TEXT NOT NULL,prefix BLOB NOT NULL,completed REAL);
        INSERT INTO meta VALUES('\(automaticConnection.fingerprint)',CAST('prefix' AS BLOB),1700000000);
        CREATE TABLE objects(id INTEGER PRIMARY KEY,key BLOB UNIQUE NOT NULL,name TEXT NOT NULL,normalized TEXT NOT NULL,parent TEXT NOT NULL,extension TEXT NOT NULL,size INTEGER NOT NULL,modified REAL NOT NULL,etag TEXT NOT NULL,seen INTEGER NOT NULL,deleted INTEGER NOT NULL DEFAULT 0);
        INSERT INTO objects VALUES(1,CAST('prefix/legacy.wav' AS BLOB),'legacy.wav','legacy.wav','prefix/','wav',42,1700000000,'opaque',1,0);
        CREATE VIRTUAL TABLE terms USING fts5(name,path,tokenize='unicode61',prefix='2 3 4');
        INSERT INTO terms(rowid,name,path) VALUES(1,'legacy.wav','prefix/legacy.wav');
        CREATE TABLE scan(id INTEGER PRIMARY KEY,token TEXT,state TEXT NOT NULL);
        CREATE TABLE tokens(token TEXT PRIMARY KEY);
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(old,schema,nil,nil,nil),SQLITE_OK); sqlite3_close(old)
        let migrated = CatalogStore(directory:directory,fingerprint:automaticConnection.fingerprint,prefix:"prefix")
        let rows = try await migrated.search(CatalogQuery(text:"legacy")); XCTAssertEqual(rows.count,1)
        let summary = try await migrated.summary(); XCTAssertEqual(summary.count,1); XCTAssertNotNil(summary.lastCompleted)
        try await migrated.recordUploadHints([hint("prefix/new.wav")])
        let hints = try await migrated.pendingChanges(); XCTAssertEqual(hints.count,1)
    }
    func testLegacyVerifiedUploadRecordsAreBackfilledOnEngineOpen() async throws {
        var job = try uploadJob(); job.status = .uploaded; job.phase = .complete; job.verifiedAt = Date()
        let records = root.appendingPathComponent("records")
        var queue: UploadQueueStore? = try UploadQueueStore(directory:records); try queue!.insert([job]); queue = nil
        var old: OpaquePointer?; XCTAssertEqual(sqlite3_open(records.appendingPathComponent("uploads.sqlite").path,&old),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(old,"DROP TABLE catalog_outbox",nil,nil,nil),SQLITE_OK); sqlite3_close(old)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory:records)
        let hints = try await engine.pendingCatalogHints(destination:automaticConnection.fingerprint)
        XCTAssertEqual(hints.map(\.key),[job.key]); await engine.closeForTesting()
    }
    func testTargetedUploadOverwriteRenameAndDeleteUpdatesFTS() async throws {
        let remote = MutableCatalogRemote()
        await remote.put(entry("prefix/original.wav"))
        try await store.recordUploadHints([hint("prefix/original.wav")])
        _ = try await CatalogChangeReconciler.drain(store:store,remote:remote)
        var rows = try await store.search(CatalogQuery(text:"original")); XCTAssertEqual(rows.count,1)
        await remote.put(entry("prefix/original.wav",size:900))
        try await store.recordUploadHints([hint("prefix/original.wav")])
        _ = try await CatalogChangeReconciler.drain(store:store,remote:remote)
        rows = try await store.search(CatalogQuery(text:"original")); XCTAssertEqual(rows.first?.size,900)
        await remote.put(entry("prefix/renamed.wav",size:900)); await remote.remove("prefix/original.wav")
        try await store.recordWorkerChanges(feed(latest:2,next:2,events:[(1,"original.wav",false),(2,"renamed.wav",false)]),after:0)
        _ = try await CatalogChangeReconciler.drain(store:store,remote:remote)
        rows = try await store.search(CatalogQuery(text:"original")); XCTAssertTrue(rows.isEmpty)
        rows = try await store.search(CatalogQuery(text:"renamed")); XCTAssertEqual(rows.count,1)
        await remote.remove("prefix/renamed.wav")
        try await store.recordWorkerChanges(feed(latest:3,next:3,events:[(3,"renamed.wav",false)]),after:2)
        _ = try await CatalogChangeReconciler.drain(store:store,remote:remote)
        let summary = try await store.summary(); XCTAssertEqual(summary.count,0)
        let lists = await remote.lists; XCTAssertEqual(lists,0,"Exact changes require HEADs, not full inventory scans")
    }
    func testWorkerCursorAndPendingChangesSurviveRestartAndDuplicateDelivery() async throws {
        let page = feed(latest:1,next:1,events:[(1,"new.wav",false)])
        try await store.recordWorkerChanges(page,after:0)
        try await store.recordWorkerChanges(page,after:0)
        let pending = try await store.pendingChanges(); XCTAssertEqual(pending.count,1)
        store = nil
        store = CatalogStore(directory:root.appendingPathComponent("catalog"),fingerprint:automaticConnection.fingerprint,prefix:"prefix")
        let cursor = try await store.workerCursor(); XCTAssertEqual(cursor.sequence,1); XCTAssertEqual(cursor.session,"worker-one")
        let restored = try await store.pendingChanges(); XCTAssertEqual(restored.first?.revision,pending.first?.revision)
        let remote = MutableCatalogRemote(); await remote.put(entry("prefix/new.wav"))
        _ = try await CatalogChangeReconciler.drain(store:store,remote:remote)
        let remaining = try await store.pendingChanges(); XCTAssertTrue(remaining.isEmpty)
    }
    func testOldScanAndMissingConfirmationCannotOverrideNewerHint() async throws {
        let scan = try await store.beginScan(fresh:true)
        try await store.commit(page:InventoryPage(objects:[entry("prefix/song.wav")],nextToken:nil),scan:scan)
        try await store.recordUploadHints([hint("prefix/song.wav")])
        do { try await store.confirmMissing(id:1,scanID:scan.id); XCTFail("Old HEAD cannot delete a changed key") } catch CatalogFailure.superseded {} catch { XCTFail("\(error)") }
        do { try await store.finish(scanID:scan.id); XCTFail("Stale scan cannot publish freshness") } catch {}
        let fresh = try await store.beginScan(fresh:false); XCTAssertNotEqual(fresh.id,scan.id)
        do { try await store.commit(page:InventoryPage(objects:[entry("prefix/song.wav",size:1)],nextToken:nil),scan:scan); XCTFail("Old LIST must fail") } catch {}
        let rows = try await store.search(CatalogQuery(text:"song")); XCTAssertEqual(rows.first?.size,42)
    }
    func testLateHeadAndAcknowledgementCannotConsumeNewerSameKeyHint() async throws {
        try await store.recordUploadHints([hint("prefix/song.wav")])
        let originals = try await store.pendingChanges(); let original = try XCTUnwrap(originals.first)
        try await store.recordUploadHints([hint("prefix/song.wav")])
        do { try await store.applyChangedObject(entry("prefix/song.wav"),key:"prefix/song.wav",change:original); XCTFail("Stale HEAD") } catch {}
        try await store.acknowledgeChange(original)
        let pending = try await store.pendingChanges(); XCTAssertEqual(pending.count,1); XCTAssertGreaterThan(pending[0].revision,original.revision)
    }
    func testDirectoryRenameReconcilesOnlyItsSubtreeAndPreservesNeighbor() async throws {
        let remote = MutableCatalogRemote()
        let scan = try await store.beginScan(fresh:true)
        try await store.commit(page:InventoryPage(objects:[entry("prefix/old/a.wav"),entry("prefix/old/deep/b.wav"),entry("prefix/old-neighbor/keep.wav")],nextToken:nil),scan:scan)
        try await store.finish(scanID:scan.id)
        await remote.put(entry("prefix/new/a.wav")); await remote.put(entry("prefix/new/deep/b.wav")); await remote.put(entry("prefix/old-neighbor/keep.wav"))
        try await store.recordWorkerChanges(feed(latest:2,next:2,events:[(1,"old",true),(2,"new",true)]),after:0)
        _ = try await CatalogChangeReconciler.drain(store:store,remote:remote)
        let all = try await store.search(CatalogQuery(text:""))
        XCTAssertEqual(Set(all.map(\.key)),["prefix/new/a.wav","prefix/new/deep/b.wav","prefix/old-neighbor/keep.wav"])
        let lists = await remote.lists; XCTAssertEqual(lists,2,"Only old/new directory scopes should be enumerated")
    }
    func testNewerDeletionTombstoneRejectsLateParentListingEvenForUnknownKey() async throws {
        try await store.recordWorkerChanges(feed(latest:1,next:1,events:[(1,"folder",true)]),after:0)
        let parentChanges = try await store.pendingChanges(); let parent = try XCTUnwrap(parentChanges.first)
        try await store.recordUploadHints([hint("prefix/folder/deleted.wav")])
        let all = try await store.pendingChanges(); let deletion = try XCTUnwrap(all.first { $0.key == "prefix/folder/deleted.wav" })
        try await store.applyChangedObject(nil,key:deletion.key,change:deletion); try await store.acknowledgeChange(deletion)
        try await store.applyChangedObjects([entry(deletion.key)],change:parent)
        let rows = try await store.search(CatalogQuery(text:"deleted")); XCTAssertTrue(rows.isEmpty)
    }
    func testFailedKeyDoesNotStarveNewerHintsInLaterBatches() async throws {
        let remote = MutableCatalogRemote(); await remote.deny("prefix/denied.wav"); await remote.put(entry("prefix/new.wav"))
        try await store.recordUploadHints([hint("prefix/denied.wav"),hint("prefix/new.wav")])
        do { _ = try await CatalogChangeReconciler.drain(store:store,remote:remote,maximum:1); XCTFail("Permission failure") } catch {}
        _ = try await CatalogChangeReconciler.drain(store:store,remote:remote,maximum:1)
        let rows = try await store.search(CatalogQuery(text:"new")); XCTAssertEqual(rows.count,1)
    }
    func testMassDeletionConfirmationDoesNotSurviveAnInterveningMutation() async throws {
        let scan = try await store.beginScan(fresh:true)
        try await store.commit(page:InventoryPage(objects:[entry("prefix/old.wav")],nextToken:nil),scan:scan)
        try await store.finish(scanID:scan.id)
        let missingScan = try await store.beginScan(fresh:true)
        try await store.commit(page:InventoryPage(objects:[],nextToken:nil),scan:missingScan)
        let first = try await store.largeMissingIsConfirmed(scanID:missingScan.id); XCTAssertFalse(first)
        try await store.recordUploadHints([hint("prefix/new.wav")])
        let secondScan = try await store.beginScan(fresh:true)
        try await store.commit(page:InventoryPage(objects:[],nextToken:nil),scan:secondScan)
        let second = try await store.largeMissingIsConfirmed(scanID:secondScan.id); XCTAssertFalse(second)
    }
    func testPermissionFailuresStayPendingWithoutBlockingOtherKeysOrBecomingDeletion() async throws {
        let remote = MutableCatalogRemote(); await remote.put(entry("prefix/denied.wav")); await remote.put(entry("prefix/allowed.wav"))
        try await store.recordUploadHints([hint("prefix/denied.wav"),hint("prefix/allowed.wav")])
        await remote.deny("prefix/denied.wav")
        do { _ = try await CatalogChangeReconciler.drain(store:store,remote:remote); XCTFail("Expected permission failure") } catch {}
        let pending = try await store.pendingChanges(); XCTAssertEqual(pending.map(\.key),["prefix/denied.wav"])
        let rows = try await store.search(CatalogQuery(text:"allowed")); XCTAssertEqual(rows.count,1)
        await remote.allow("prefix/denied.wav"); _ = try await CatalogChangeReconciler.drain(store:store,remote:remote)
        let summary = try await store.summary(); XCTAssertEqual(summary.count,2)
    }
    func testFeedGapsRestartsAndInvalidSequencesRequireSafeReconciliation() async throws {
        let initial = try await store.beginScan(fresh:true)
        try await store.commit(page:InventoryPage(objects:[],nextToken:nil),scan:initial); try await store.finish(scanID:initial.id)
        try await store.recordWorkerChanges(feed(latest:0,next:0,events:[]),after:0)
        let needed = try await store.needsReconciliation(); XCTAssertTrue(needed)
        let scan = try await store.beginScan(fresh:true)
        try await store.recordWorkerChanges(feed(first:10,latest:10,next:10,gap:true,events:[(10,"file.wav",false)]),after:0)
        do { try await store.commit(page:InventoryPage(objects:[],nextToken:nil),scan:scan); XCTFail("Gap invalidates old baseline") } catch {}
        let before = try await store.workerCursor()
        do { try await store.recordWorkerChanges(feed(latest:12,next:12,events:[(12,"bad.wav",false)]),after:10); XCTFail("Noncontiguous feed") } catch {}
        let after = try await store.workerCursor(); XCTAssertEqual(after.sequence,before.sequence)
        try await store.recordWorkerChanges(feed(session:"replacement",latest:0,next:0,gap:true,events:[]),after:10)
        let replaced = try await store.workerCursor(); XCTAssertEqual(replaced.session,"replacement"); XCTAssertEqual(replaced.sequence,0)
    }
    func testWorkerCursorIsNotAdvancedIfQueueTransactionFails() async throws {
        _ = try await store.summary()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog/catalog.sqlite").path,&connection),SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TRIGGER fixture_fail BEFORE INSERT ON pending_changes BEGIN SELECT RAISE(ABORT,'fixture'); END;",nil,nil,nil),SQLITE_OK)
        do { try await store.recordWorkerChanges(feed(latest:1,next:1,events:[(1,"file.wav",false)]),after:0); XCTFail("Injected failure") } catch {}
        let cursor = try await store.workerCursor(); XCTAssertNil(cursor.session); XCTAssertEqual(cursor.sequence,0)
        let changes = try await store.pendingChanges(); XCTAssertTrue(changes.isEmpty)
    }
}

@MainActor final class AutomaticCatalogControllerTests: XCTestCase {
    func testAutomaticBaselineAndIncrementalUpdatesWithoutRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-auto-controller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let remote = MutableCatalogRemote()
        let controller = CatalogController(root:root,automaticInterval:.milliseconds(10),makeRemote:{ _ in remote })
        controller.configure(connection:automaticConnection); controller.enableAutomaticUpdates()
        defer { controller.stopAutomaticUpdates() }
        try await eventually { controller.summary.lastCompleted != nil }
        await remote.put(entry("prefix/vocals.wav"))
        try await controller.recordUploadHints([UploadCatalogHint(id:"completed-upload",destination:automaticConnection.fingerprint,key:"prefix/vocals.wav")])
        try await eventually { controller.summary.count == 1 }
        await controller.search(CatalogQuery(text:"voc")); XCTAssertEqual(controller.results.count,1)
        await remote.remove("prefix/vocals.wav"); await remote.put(entry("prefix/renamed.wav"))
        let page: [String:Any] = ["version":1,"session":"fixture-worker","first":1,"latest":2,"next":2,"gap":false,"hasMore":false,
                                 "events":[["sequence":1,"path":"vocals.wav","recursive":false],["sequence":2,"path":"renamed.wav","recursive":false]]]
        try await controller.recordWorkerChanges(JSONSerialization.data(withJSONObject:page),after:0)
        try await eventually {
            await controller.search(CatalogQuery(text:"renamed"))
            return controller.results.count == 1
        }
        await controller.search(CatalogQuery(text:"voc")); XCTAssertTrue(controller.results.isEmpty)
        controller.pause(); XCTAssertTrue(controller.automaticPaused)
        await remote.remove("prefix/renamed.wav")
        let deletion: [String:Any] = ["version":1,"session":"fixture-worker","first":1,"latest":3,"next":3,"gap":false,"hasMore":false,
                                     "events":[["sequence":3,"path":"renamed.wav","recursive":false]]]
        try await controller.recordWorkerChanges(JSONSerialization.data(withJSONObject:deletion),after:2)
        try await Task.sleep(for:.milliseconds(40)); XCTAssertEqual(controller.summary.count,1,"Pause retains pending updates")
        controller.refresh()
        try await eventually { controller.summary.count == 0 }
    }
    func testClearedUploadHistoryStillDeliversItsDurableHintAutomatically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-auto-outbox-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let remote = MutableCatalogRemote()
        let catalog = CatalogController(root:root,automaticInterval:.milliseconds(10),makeRemote:{ _ in remote })
        catalog.configure(connection:automaticConnection); catalog.enableAutomaticUpdates()
        defer { catalog.stopAutomaticUpdates() }
        try await eventually { catalog.summary.lastCompleted != nil }
        let listsBefore = await remote.lists
        let file = root.appendingPathComponent("source.wav"); try Data().write(to:file)
        var job = DirectUploadJob(batchID:UUID(),sourcePath:file.path,source:try UploadSourceIdentity.capture(file),destination:automaticConnection.fingerprint,key:"prefix/source.wav",partSize:5*1_048_576)
        job.status = .uploaded; job.phase = .complete; job.verifiedAt = Date()
        let records = root.appendingPathComponent("records")
        var queue: UploadQueueStore? = try UploadQueueStore(directory:records)
        try queue!.insert([job]); try queue!.removeFinished(); queue = nil
        await remote.put(entry(job.key,size:0))
        let uploads = DirectUploadController(defaultDirectory:records,rememberLocation:false)
        uploads.catalogDestination = { automaticConnection.fingerprint }
        uploads.catalogDelivery = { try await catalog.recordUploadHints($0) }
        await uploads.restoreIfNeeded()
        try await eventually { catalog.summary.count == 1 }
        XCTAssertTrue(uploads.jobs.isEmpty)
        let listsAfter = await remote.lists; XCTAssertEqual(listsAfter,listsBefore,"Delivery must use targeted metadata, not rediscovery")
        await uploads.relinquishForTesting()
        queue = try UploadQueueStore(directory:records)
        XCTAssertTrue(try queue!.pendingCatalogHints(destination:automaticConnection.fingerprint).isEmpty)
        queue = nil
    }
    func testPeriodicReconciliationDiscoversOutsideRenamesAndDeletesWithoutHints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-auto-external-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let remote = MutableCatalogRemote(); await remote.put(entry("prefix/before.wav"))
        let catalog = CatalogController(root:root,automaticInterval:.milliseconds(10),reconciliationInterval:0.05,minimumScanSpacing:0.05,makeRemote:{ _ in remote })
        catalog.configure(connection:automaticConnection); catalog.enableAutomaticUpdates()
        defer { catalog.stopAutomaticUpdates() }
        try await eventually { catalog.summary.lastCompleted != nil && catalog.summary.count == 1 }
        await remote.remove("prefix/before.wav"); await remote.put(entry("prefix/after.wav"))
        try await eventually { await catalog.search(CatalogQuery(text:"after")); return catalog.results.count == 1 }
        await catalog.search(CatalogQuery(text:"before")); XCTAssertTrue(catalog.results.isEmpty)
        await remote.remove("prefix/after.wav")
        try await eventually { catalog.summary.count == 0 }
    }
    func testExpiredContinuationAutomaticallyRestartsWithoutLosingInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-expired-token-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let remote = ExpiredCatalogTokenFixture()
        let catalog = CatalogController(root:root,automaticInterval:.milliseconds(10),minimumScanSpacing:0.05,makeRemote:{ _ in remote })
        catalog.configure(connection:automaticConnection); catalog.enableAutomaticUpdates()
        defer { catalog.stopAutomaticUpdates() }
        try await eventually { catalog.summary.lastCompleted != nil && catalog.summary.count == 2 }
        let starts = await remote.starts; XCTAssertEqual(starts,2)
    }
    func testBulkOutsideDeletionRequiresTwoCompleteInventoriesThenUpdatesAutomatically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-auto-mass-delete-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let remote = MutableCatalogRemote()
        for i in 0..<200 { await remote.put(entry("prefix/file\(i).wav")) }
        let catalog = CatalogController(root:root,automaticInterval:.milliseconds(10),reconciliationInterval:0.05,minimumScanSpacing:0.05,makeRemote:{ _ in remote })
        catalog.configure(connection:automaticConnection); catalog.enableAutomaticUpdates()
        defer { catalog.stopAutomaticUpdates() }
        try await eventually { catalog.summary.lastCompleted != nil && catalog.summary.count == 200 }
        let before = await remote.lists
        for i in 0..<200 { await remote.remove("prefix/file\(i).wav") }
        try await eventually { catalog.summary.count == 0 }
        let after = await remote.lists, heads = await remote.heads
        XCTAssertGreaterThanOrEqual(after-before,2)
        XCTAssertEqual(heads,200,"Every removed entry still requires an independent absence check")
    }
    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Automatic catalog update did not complete")
    }
}

private actor ExpiredCatalogTokenFixture: ObjectInventoryRemote {
    private(set) var starts = 0
    func list(token:String?) async throws -> InventoryPage {
        if token != nil { throw CatalogFailure.http(400) }
        starts += 1
        return InventoryPage(objects:starts == 1 ? [entry("prefix/first.wav")] : [entry("prefix/first.wav"),entry("prefix/last.wav")],nextToken:starts == 1 ? "expired" : nil)
    }
    func isMissing(key:String) async throws -> Bool { false }
}
