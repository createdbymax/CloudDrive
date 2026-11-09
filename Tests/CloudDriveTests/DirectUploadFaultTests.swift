import XCTest
import CryptoKit
import SQLite3
@testable import CloudDrive

private let faultConnection = Connection(endpoint: "https://fault-fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "prefix", accessKey: "synthetic-access", secretKey: "synthetic-secret")

private actor FaultMultipartRemote: MultipartRemote {
    private var object: RemoteUploadObject?
    private var jobID: UUID?
    private var payloads: [Int: Data] = [:]
    private var uploadCalls = 0
    private var abortCalls = 0
    private var createCalls = 0
    private var holdingHead = false
    private var headEntered = false
    private var headContinuation: CheckedContinuation<Void, Never>?
    private var pausePart = false
    private var partEntered = false
    private var failCreate = false
    private var offline = false
    private var headCalls = 0

    func holdInitialHead() { holdingHead = true }
    func releaseHead() { holdingHead = false; headContinuation?.resume(); headContinuation = nil }
    func didEnterHead() -> Bool { headEntered }
    func holdParts() { pausePart = true }
    func didEnterPart() -> Bool { partEntered }
    func loseCreateResponse() { failCreate = true }
    func goOffline() { offline = true }
    func heads() -> Int { headCalls }
    func counts() -> (creates: Int, uploads: Int, aborts: Int) { (createCalls, uploadCalls, abortCalls) }

    func head(key: String) async throws -> RemoteUploadObject? {
        headCalls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        headEntered = true
        if holdingHead { await withCheckedContinuation { headContinuation = $0 } }
        return object
    }
    func create(key: String, jobID: UUID) async throws -> String {
        self.jobID = jobID; createCalls += 1
        if failCreate { throw URLError(.networkConnectionLost) }
        return "fault-session"
    }
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart] {
        payloads.map { .init(number: $0.key, etag: Insecure.MD5.hash(data: $0.value).hex, size: Int64($0.value.count)) }
    }
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String {
        partEntered = true; uploadCalls += 1
        if pausePart { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        payloads[number] = data
        return Insecure.MD5.hash(data: data).hex
    }
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws {
        var digestBytes = Data(), size: Int64 = 0
        for part in parts.sorted(by: { $0.number < $1.number }) {
            guard let data = payloads[part.number] else { throw MultipartRemoteError.invalidResponse }
            digestBytes.append(Data(Insecure.MD5.hash(data: data))); size += Int64(data.count)
        }
        object = .init(size: size, etag: Insecure.MD5.hash(data: digestBytes).hex + "-\(parts.count)", jobID: jobID?.uuidString)
    }
    func putEmpty(key: String, jobID: UUID) async throws {
        object = .init(size: 0, etag: Insecure.MD5.hash(data: Data()).hex, jobID: jobID.uuidString)
    }
    func abort(key: String, uploadID: String) async throws { abortCalls += 1; payloads = [:] }
}

final class DirectUploadFaultTests: XCTestCase {
    private var root: URL!
    private var records: URL { root.appendingPathComponent("records") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("direct-fault-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func job(size: Int = 1024) throws -> DirectUploadJob {
        let file = root.appendingPathComponent("source.bin")
        try Data(repeating: 61, count: size).write(to: file)
        return DirectUploadJob(batchID: UUID(), sourcePath: file.path, source: try UploadSourceIdentity.capture(file), destination: faultConnection.fingerprint, key: "prefix/source.bin", partSize: 5 * 1_048_576)
    }
    private func insert(_ job: DirectUploadJob) throws {
        let store = try UploadQueueStore(directory: records); try store.insert([job])
    }
    private func waitFor(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture did not reach the expected operation within one second")
    }

    func testCancellationDuringPartPersistsPauseWithoutAbortingRemoteSession() async throws {
        let original = try job(); try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = FaultMultipartRemote(); await remote.holdParts()
        let task = Task { try await engine.run(id: original.id, remote: remote, destination: faultConnection.fingerprint) { _ in } }
        try await waitFor { await remote.didEnterPart() }
        task.cancel(); try await task.value
        let snapshot = await engine.snapshot()
        let saved = try XCTUnwrap(snapshot.first)
        let counts = await remote.counts()
        XCTAssertEqual(saved.status, .paused)
        XCTAssertEqual(saved.uploadID, "fault-session")
        XCTAssertNil(saved.verifiedAt)
        XCTAssertEqual(counts.aborts, 0, "Pause must retain multipart parts for resume")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.sourcePath))
    }

    func testSecondRunAndStateSwitchAreRejectedWhileRemoteRequestIsInFlight() async throws {
        let original = try job(); try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = FaultMultipartRemote(); await remote.holdInitialHead()
        let task = Task { try await engine.run(id: original.id, remote: remote, destination: faultConnection.fingerprint) { _ in } }
        try await waitFor { await remote.didEnterHead() }
        do {
            try await engine.run(id: original.id, remote: remote, destination: faultConnection.fingerprint) { _ in }
            XCTFail("A second writer must be rejected")
        } catch is DirectUploadFailure { }
        do {
            _ = try await engine.open(directory: root.appendingPathComponent("other-records"))
            XCTFail("State cannot switch during an active writer")
        } catch is DirectUploadFailure { }
        await remote.releaseHead(); try await task.value
        let saved = await engine.snapshot(), counts = await remote.counts()
        XCTAssertEqual(saved[0].status, .uploaded); XCTAssertEqual(counts.creates, 1)
    }

    func testLostInitiationResponseNeverSendsUnjournaledParts() async throws {
        let original = try job(); try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = FaultMultipartRemote(); await remote.loseCreateResponse()
        do {
            try await engine.run(id: original.id, remote: remote, destination: faultConnection.fingerprint) { _ in }
            XCTFail("Initiation response was lost")
        } catch is URLError { }
        let saved = await engine.snapshot(), counts = await remote.counts()
        XCTAssertNil(saved[0].uploadID); XCTAssertEqual(saved[0].status, .attention)
        XCTAssertEqual(counts.uploads, 0); XCTAssertEqual(counts.creates, 1)
    }

    func testExplicitRestartCannotDiscardALiveUpload() async throws {
        var original = try job(); original.uploadID = "fault-session"; original.status = .paused; try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        do {
            _ = try await engine.restartExpired(id: original.id, remote: FaultMultipartRemote(), destination: faultConnection.fingerprint)
            XCTFail("Live sessions must be resumed rather than reset")
        } catch is DirectUploadFailure { }
        let saved = await engine.snapshot()
        XCTAssertEqual(saved[0].uploadID, original.uploadID)
        XCTAssertEqual(saved[0].status, .paused)
    }

    func testFailedBatchInsertRollsBackEveryJob() throws {
        let original = try job()
        let store = try UploadQueueStore(directory: records)
        XCTAssertThrowsError(try store.insert([original, original]), "Duplicate IDs must fail the entire admission transaction")
        XCTAssertTrue(try store.load().isEmpty)
        try store.insert([original]); XCTAssertEqual(try store.load().count, 1)
    }

    func testQueueEntryLimitRejectsBatchBeforeAnyAdmission() throws {
        let original = try job()
        let store = try UploadQueueStore(directory: records)
        let oversizedBatch = (0..<10_001).map { _ -> DirectUploadJob in var copy = original; copy.id = UUID(); return copy }
        XCTAssertThrowsError(try store.insert(oversizedBatch))
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testSourceReplacingSameFilenameIsNotTreatedAsSameFile() throws {
        let original = try job()
        try FileManager.default.removeItem(atPath: original.sourcePath)
        try Data(repeating: 61, count: Int(original.source.size)).write(to: URL(fileURLWithPath: original.sourcePath))
        let replacement = try UploadSourceIdentity.capture(URL(fileURLWithPath: original.sourcePath))
        XCTAssertNotEqual(original.source, replacement)
    }

    func testQueuedOfflineCancellationNeverContactsRemote() async throws {
        let original = try job(); try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = FaultMultipartRemote(); await remote.goOffline()
        let saved = try await engine.cancel(id: original.id, remote: remote, destination: faultConnection.fingerprint)
        let heads = await remote.heads(), counts = await remote.counts()
        XCTAssertEqual(saved[0].status, .cancelled)
        XCTAssertEqual(heads, 0); XCTAssertEqual(counts.uploads, 0); XCTAssertEqual(counts.aborts, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.sourcePath))
    }

    func testUnknownInitiationCanCancelOfflineBecauseNoPayloadWasSent() async throws {
        var original = try job(); original.phase = .initiating; original.status = .attention; try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = FaultMultipartRemote(); await remote.goOffline()
        let saved = try await engine.cancel(id: original.id, remote: remote, destination: faultConnection.fingerprint)
        let heads = await remote.heads()
        XCTAssertEqual(saved[0].status, .cancelled); XCTAssertEqual(heads, 0)
    }

    func testAmbiguousEmptyCommitCannotBeLocallyCancelledWithoutReconciliation() async throws {
        var original = try job(size: 0); original.phase = .completing; original.status = .attention; try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = FaultMultipartRemote(); await remote.goOffline()
        do {
            _ = try await engine.cancel(id: original.id, remote: remote, destination: faultConnection.fingerprint)
            XCTFail("An empty PUT may already have committed and must be checked remotely")
        } catch is URLError { }
        let saved = await engine.snapshot(), heads = await remote.heads()
        XCTAssertEqual(heads, 1); XCTAssertNotEqual(saved[0].status, .cancelled)
    }

    func testExplicitSameFolderRecoveryReloadsTheDurableQueue() async throws {
        let original = try job(); try insert(original)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        var modified = original; modified.status = .paused; modified.message = "Restored durable metadata"
        let data = try JSONEncoder().encode(modified)
        var database: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(records.appendingPathComponent("uploads.sqlite").path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        XCTAssertEqual(sqlite3_prepare_v2(database, "UPDATE jobs SET data=? WHERE id=?", -1, &statement, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_text(statement, 2, original.id.uuidString, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        let cached = try await engine.open(directory: records)
        XCTAssertNotEqual(cached[0].message, modified.message)
        let reloaded = try await engine.open(directory: records, recoverExisting: true)
        XCTAssertEqual(reloaded[0].message, modified.message); XCTAssertEqual(reloaded[0].status, .paused)
    }

    func testRecoverMissingDatabaseDoesNotCreateAnEmptyQueue() async throws {
        let missing = root.appendingPathComponent("missing-records")
        let engine = DirectUploadEngine()
        do { _ = try await engine.open(directory: missing, recoverExisting: true); XCTFail("Missing records must not be replaced with an empty queue") }
        catch is DirectUploadFailure { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testReplacedRecordsDirectoryRejectsReadsAndWritesWithoutTouchingReplacement() throws {
        let original = try job()
        let store = try UploadQueueStore(directory: records); try store.insert([original])
        let detached = root.appendingPathComponent("detached-records")
        try FileManager.default.moveItem(at: records, to: detached)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try store.load())
        var modified = original; modified.message = "Must never be saved"
        XCTAssertThrowsError(try store.save(modified))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: records.path).isEmpty)
        // The original location retains its last durable job after the old connection is closed.
        var database: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(detached.appendingPathComponent("uploads.sqlite").path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT data FROM jobs", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let bytes = try XCTUnwrap(sqlite3_column_blob(statement, 0))
        let recovered = try JSONDecoder().decode(DirectUploadJob.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        XCTAssertEqual(recovered.message, original.message)
    }

    func testUnwritableRecordsDirectoryPreservesLastCommittedState() throws {
        let original = try job()
        let store = try UploadQueueStore(directory: records); try store.insert([original])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: records.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: records.path) }
        var modified = original; modified.message = "Uncommitted state"
        XCTAssertThrowsError(try store.save(modified), "An unwritable journal location must fail the transition")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: records.path)
        let loaded = try store.load()
        XCTAssertEqual(loaded[0].message, original.message)
        XCTAssertEqual(loaded[0].status, original.status)
    }
}
