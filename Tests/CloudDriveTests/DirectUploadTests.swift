import XCTest
import CryptoKit
import SQLite3
@testable import CloudDrive

private let fixtureConnection = Connection(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "prefix", accessKey: "fixture-access", secretKey: "fixture-secret")

private actor MultipartFixture: MultipartRemote {
    var uploadID = "fixture-session"
    var jobID: UUID?
    var payloads: [Int: Data] = [:]
    var calls: [Int: Int] = [:]
    var object: RemoteUploadObject?
    var completedPayload = Data()
    var failPart: Int?
    var loseCompletion = false
    var expired = false
    var aborts = 0
    var creates = 0
    var badETag = false
    func configure(failPart: Int? = nil, loseCompletion: Bool = false, expired: Bool = false, badETag: Bool = false) {
        self.failPart = failPart; self.loseCompletion = loseCompletion; self.expired = expired; self.badETag = badETag
    }
    func seed(job: DirectUploadJob, part: Int, data: Data) { jobID = job.id; payloads[part] = data }
    func head(key: String) async throws -> RemoteUploadObject? { object }
    func create(key: String, jobID: UUID) async throws -> String { creates += 1; self.jobID = jobID; return uploadID }
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart] {
        if expired { throw MultipartRemoteError.expired }
        return payloads.map { .init(number: $0.key, etag: Insecure.MD5.hash(data: $0.value).hex, size: Int64($0.value.count)) }.sorted { $0.number < $1.number }
    }
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String {
        calls[number, default: 0] += 1
        if failPart == number {
            try await Task.sleep(for: .milliseconds(150))
            throw MultipartRemoteError.http(503)
        }
        payloads[number] = data
        return badETag ? "bad-digest" : Insecure.MD5.hash(data: data).hex
    }
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws {
        var hashes = Data(), full = Data()
        for part in parts.sorted(by: { $0.number < $1.number }) {
            guard let data = payloads[part.number], Insecure.MD5.hash(data: data).hex == part.md5 else { throw MultipartRemoteError.checksumMismatch }
            hashes.append(Data(Insecure.MD5.hash(data: data))); full.append(data)
        }
        completedPayload = full
        object = .init(size: Int64(full.count), etag: Insecure.MD5.hash(data: hashes).hex + "-\(parts.count)", jobID: jobID?.uuidString)
        if loseCompletion { throw URLError(.networkConnectionLost) }
    }
    func putEmpty(key: String, jobID: UUID) async throws {
        object = .init(size: 0, etag: Insecure.MD5.hash(data: Data()).hex, jobID: jobID.uuidString)
    }
    func abort(key: String, uploadID: String) async throws { aborts += 1; payloads = [:]; expired = true }
    func removePart(_ number: Int) { payloads.removeValue(forKey: number) }
    func counters() -> [Int: Int] { calls }
    func counts() -> (Int, Int) { (creates, aborts) }
    func payload() -> Data { completedPayload }
}

final class DirectUploadTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("direct-upload-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var records: URL { root.appendingPathComponent("records") }

    private func makeJob(size: Int = 12 * 1_048_576 + 123, name: String = "original.mov") throws -> (DirectUploadJob, Data) {
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sourceURL = root.appendingPathComponent(name); try data.write(to: sourceURL)
        let job = DirectUploadJob(batchID: UUID(), sourcePath: sourceURL.path, source: try UploadSourceIdentity.capture(sourceURL), destination: fixtureConnection.fingerprint,
                                  key: "prefix/" + name, partSize: 5 * 1_048_576)
        return (job, data)
    }
    private func seed(_ job: DirectUploadJob) throws {
        let store = try UploadQueueStore(directory: records)
        var metadata = job; metadata.parts = []
        try store.insert([metadata])
        for part in job.parts { try store.savePart(part, job: job) }
    }

    func testVerifiedUploadHintSurvivesClearingHistoryAndEngineRestart() async throws {
        let (job,_) = try makeJob(size:0,name:"indexed.wav"); try seed(job)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory:records)
        let remote = MultipartFixture()
        try await engine.run(id:job.id,remote:remote,destination:fixtureConnection.fingerprint) { _ in }
        let hints = try await engine.pendingCatalogHints(destination:fixtureConnection.fingerprint)
        XCTAssertEqual(hints.count,1); XCTAssertEqual(hints.first?.key,job.key)
        _ = try await engine.clearFinished()
        await engine.closeForTesting()
        let restored = DirectUploadEngine(); _ = try await restored.open(directory:records)
        let replay = try await restored.pendingCatalogHints(destination:fixtureConnection.fingerprint); XCTAssertEqual(replay,hints)
        try await restored.acknowledgeCatalogHints(replay)
        let remaining = try await restored.pendingCatalogHints(destination:fixtureConnection.fingerprint); XCTAssertTrue(remaining.isEmpty)
        await restored.closeForTesting()
    }
    func testCompletionDiscoveredDuringCancellationAlsoEmitsDurableHint() async throws {
        var (job,_) = try makeJob(size:0,name:"recovered.wav")
        job.status = .paused; job.phase = .completing
        try seed(job)
        let remote = MultipartFixture(); try await remote.putEmpty(key:job.key,jobID:job.id)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory:records)
        let result = try await engine.cancel(id:job.id,remote:remote,destination:fixtureConnection.fingerprint)
        XCTAssertEqual(result.first?.status,.uploaded)
        let hints = try await engine.pendingCatalogHints(destination:fixtureConnection.fingerprint)
        XCTAssertEqual(hints.map(\.key),[job.key])
        await engine.closeForTesting()
    }
    func test400GBUsesLessThan10000PartsAndOnlyMetadataAdmission() async throws {
        let source = root.appendingPathComponent("400GB.mov")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 400_000_000_000); try handle.close()
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let result = try await engine.enqueue(urls: [source], connection: fixtureConnection, excluded: [])
        let job = try XCTUnwrap(result.jobs.first)
        XCTAssertEqual(job.source.size, 400_000_000_000)
        XCTAssertEqual(job.partSize, 39 * 1_048_576); XCTAssertEqual(job.partCount, 9782)
        let attributes = try FileManager.default.attributesOfItem(atPath: records.appendingPathComponent("uploads.sqlite").path)
        XCTAssertLessThan((attributes[.size] as! NSNumber).int64Value, 1_048_576)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: records.path)), ["owner.lock", "uploads.sqlite"])
    }

    func testProcessRestartSkipsConfirmedPartAndVerifiesFullPayload() async throws {
        let (job, original) = try makeJob(); try seed(job)
        let remote = MultipartFixture(); await remote.configure(failPart: 2)
        var engine: DirectUploadEngine? = DirectUploadEngine(); _ = try await engine!.open(directory: records)
        do { try await engine!.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }; XCTFail("Should interrupt") }
        catch MultipartRemoteError.http(503) { }
        let interrupted = await engine!.snapshot()
        XCTAssertTrue(interrupted[0].parts.contains { $0.number == 1 })
        engine = nil
        await remote.configure()
        let restarted = DirectUploadEngine(); _ = try await restarted.open(directory: records)
        try await restarted.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }
        let counts = await remote.counters(), saved = await restarted.snapshot(), uploaded = await remote.payload()
        XCTAssertEqual(counts[1], 1); XCTAssertEqual(counts[2], 2); XCTAssertEqual(counts[3], 1)
        XCTAssertEqual(saved[0].status, .uploaded); XCTAssertNotNil(saved[0].verifiedAt)
        XCTAssertEqual(SHA256.hash(data: uploaded).hex, SHA256.hash(data: original).hex)
        let creates = await remote.counts(); XCTAssertEqual(creates.0, 1)
    }

    func testEnqueuedSecurityBookmarkCanResumeAfterEngineRestart() async throws {
        let (original, _) = try makeJob(size: 4096)
        var engine: DirectUploadEngine? = DirectUploadEngine(); _ = try await engine!.open(directory: records)
        let enqueued = try await engine!.enqueue(urls: [URL(fileURLWithPath: original.sourcePath)], connection: fixtureConnection, excluded: [])
        let job = try XCTUnwrap(enqueued.jobs.first); XCTAssertNotNil(job.bookmark)
        engine = nil
        let restarted = DirectUploadEngine(); _ = try await restarted.open(directory: records)
        try await restarted.run(id: job.id, remote: MultipartFixture(), destination: fixtureConnection.fingerprint) { _ in }
        let snapshot = await restarted.snapshot(); XCTAssertEqual(snapshot[0].status, .uploaded)
    }

    func testLostCompletionResponseRecoversWithoutSourceOrReupload() async throws {
        let (job, _) = try makeJob(size: 1_000_003); try seed(job)
        let remote = MultipartFixture(); await remote.configure(loseCompletion: true)
        var engine: DirectUploadEngine? = DirectUploadEngine(); _ = try await engine!.open(directory: records)
        do { try await engine!.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }; XCTFail("Expected lost response") }
        catch is URLError { }
        engine = nil
        try FileManager.default.removeItem(atPath: job.sourcePath)
        let restarted = DirectUploadEngine(); _ = try await restarted.open(directory: records)
        try await restarted.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }
        let snapshot = await restarted.snapshot(), counts = await remote.counters()
        XCTAssertEqual(snapshot[0].status, .uploaded); XCTAssertEqual(counts[1], 1)
    }

    func testRemotePartWithoutLocalAcknowledgementIsRecoveredByChecksum() async throws {
        var (job, source) = try makeJob(); job.uploadID = "fixture-session"; try seed(job)
        let remote = MultipartFixture(); await remote.seed(job: job, part: 1, data: Data(source.prefix(Int(job.partSize))))
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        try await engine.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }
        let calls = await remote.counters(), snapshot = await engine.snapshot()
        XCTAssertNil(calls[1]); XCTAssertEqual(snapshot[0].status, .uploaded)
    }

    func testMissingRemoteConfirmedPartIsReuploaded() async throws {
        var (job, data) = try makeJob(size: 5 * 1_048_576 + 7)
        job.uploadID = "fixture-session"
        let first = Data(data.prefix(Int(job.partSize))), digest = Insecure.MD5.hash(data: first).hex
        job.parts = [.init(number: 1, etag: digest, md5: digest, size: Int64(first.count))]
        try seed(job)
        let remote = MultipartFixture(); await remote.seed(job: job, part: 1, data: first); await remote.removePart(1)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        try await engine.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }
        let calls = await remote.counters(); XCTAssertEqual(calls[1], 1)
    }

    func testChangedSourceIsRejectedBeforeSendingData() async throws {
        let (job, _) = try makeJob(size: 1024); try seed(job)
        try Data(repeating: 42, count: 1024).write(to: URL(fileURLWithPath: job.sourcePath))
        let remote = MultipartFixture(), engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        do { try await engine.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }; XCTFail("Changed file must fail") }
        catch is DirectUploadFailure { }
        let calls = await remote.counters(), snapshot = await engine.snapshot()
        XCTAssertTrue(calls.isEmpty); XCTAssertEqual(snapshot[0].status, .attention)
    }

    func testWrongPartChecksumCannotBecomeCompletionReceipt() async throws {
        let (job, _) = try makeJob(size: 123); try seed(job)
        let remote = MultipartFixture(); await remote.configure(badETag: true)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        do { try await engine.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }; XCTFail("Bad checksum must fail") }
        catch MultipartRemoteError.checksumMismatch { }
        let snapshot = await engine.snapshot(); XCTAssertNil(snapshot[0].verifiedAt); XCTAssertEqual(snapshot[0].completedBytes, 0)
    }

    func testExpiredUploadRequiresExplicitRestart() async throws {
        var (job, _) = try makeJob(size: 128); job.uploadID = "expired-session"; try seed(job)
        let remote = MultipartFixture(); await remote.configure(expired: true)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        do { try await engine.run(id: job.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }; XCTFail("Expired session must not silently restart") }
        catch MultipartRemoteError.expired { }
        let before = await remote.counts(); XCTAssertEqual(before.0, 0)
        let reset = try await engine.restartExpired(id: job.id, remote: remote, destination: fixtureConnection.fingerprint)
        XCTAssertNil(reset[0].uploadID); XCTAssertEqual(reset[0].status, .paused)
    }

    func testCancelAbortsOwnedMultipartAndPreservesOriginal() async throws {
        var (job, _) = try makeJob(size: 128); job.uploadID = "fixture-session"; try seed(job)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = MultipartFixture()
        let snapshot = try await engine.cancel(id: job.id, remote: remote, destination: fixtureConnection.fingerprint)
        let counts = await remote.counts()
        XCTAssertEqual(snapshot[0].status, .cancelled); XCTAssertEqual(counts.1, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.sourcePath))
    }

    func testZeroByteFileHasVerifiedReceipt() async throws {
        let (job, _) = try makeJob(size: 0); try seed(job)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        try await engine.run(id: job.id, remote: MultipartFixture(), destination: fixtureConnection.fingerprint) { _ in }
        let snapshot = await engine.snapshot(); XCTAssertEqual(snapshot[0].status, .uploaded); XCTAssertEqual(snapshot[0].progress, 1)
    }

    func testDestinationCannotBeChangedOnResume() async throws {
        let (job, _) = try makeJob(size: 1); try seed(job)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        do { try await engine.run(id: job.id, remote: MultipartFixture(), destination: String(repeating: "a", count: 64)) { _ in }; XCTFail("Wrong destination") }
        catch is DirectUploadFailure { }
    }

    func testFolderDropPreservesRootAndDoesNotFollowSymlinks() async throws {
        let folder = root.appendingPathComponent("Wedding/Clips")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("cérémony a.mov"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("loop").path, withDestinationPath: root.path)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let result = try await engine.enqueue(urls: [root.appendingPathComponent("Wedding"), folder], connection: fixtureConnection, excluded: [])
        XCTAssertEqual(result.jobs.count, 1); XCTAssertEqual(result.jobs[0].key, "prefix/Wedding/Clips/cérémony a.mov"); XCTAssertEqual(result.skipped, 1)
    }

    func testDroppingVolumeParentSkipsItsUploadRecordsSubtree() async throws {
        let (original, _) = try makeJob(size: 3)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let result = try await engine.enqueue(urls: [root], connection: fixtureConnection, excluded: [])
        XCTAssertEqual(result.jobs.count, 1)
        XCTAssertEqual(result.jobs[0].source, original.source)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.jobs[0].key.hasSuffix("/original.mov"))
    }

    func testStoreIsExclusiveAndPartsRemainAcrossOpen() throws {
        var (job, _) = try makeJob(size: 123)
        let digest = Insecure.MD5.hash(data: Data((0..<123).map { UInt8(truncatingIfNeeded: $0 &* 31) })).hex
        job.parts = [.init(number: 1, etag: digest, md5: digest, size: 123)]
        try seed(job)
        let store = try UploadQueueStore(directory: records)
        XCTAssertThrowsError(try UploadQueueStore(directory: records))
        let loaded = try store.load(); XCTAssertEqual(loaded[0].parts, job.parts)
        XCTAssertEqual(loaded[0].source, job.source)
    }

    func testSingleFileRetryPublishesRevisionsAndLeavesOtherQueuedFilesAlone() async throws {
        let (first, _) = try makeJob(size: 123)
        let (second, _) = try makeJob(size: 456, name: "second.mov")
        try seed(first)
        // makeJob creates distinct source names; append to the same durable queue.
        do { let store = try UploadQueueStore(directory: records); try store.insert([second]) }
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let states = SingleUploadStateRecorder()
        let remote = MultipartFixture()
        try await engine.run(id: first.id, remote: remote, destination: fixtureConnection.fingerprint,
                             stateUpdate: { await states.record($0) }, update: { _ in })
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.first { $0.id == first.id }?.status, .uploaded)
        XCTAssertEqual(snapshot.first { $0.id == second.id }?.status, .waiting)
        let recorded = await states.values()
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertEqual(recorded.last?.jobs.first { $0.id == first.id }?.status, .uploaded)
        XCTAssertEqual(recorded.map(\.revision), recorded.map(\.revision).sorted())
    }

    func testDismissOneReceiptPreservesOtherJobsSourcesAndRemoteObject() async throws {
        let (first, _) = try makeJob(size: 123)
        let (second, _) = try makeJob(size: 456, name: "second.mov")
        try seed(first)
        do { let store = try UploadQueueStore(directory: records); try store.insert([second]) }
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let remote = MultipartFixture()
        try await engine.run(id: first.id, remote: remote, destination: fixtureConnection.fingerprint) { _ in }
        let objectBefore = try await remote.head(key: first.key)
        let after = try await engine.clearFinished(id: first.id)
        XCTAssertEqual(after.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.sourcePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.sourcePath))
        let objectAfter = try await remote.head(key: first.key)
        XCTAssertEqual(objectAfter?.etag, objectBefore?.etag)
        XCTAssertEqual(objectAfter?.jobID, first.id.uuidString)
        do { _ = try await engine.clearFinished(id: second.id); XCTFail("Unfinished records must be retained") }
        catch is DirectUploadFailure { }
        await engine.closeForTesting()
        let recovered = try UploadQueueStore(directory: records).load()
        XCTAssertEqual(recovered.map(\.id), [second.id])
        XCTAssertEqual(recovered[0].status, .waiting)
    }

    func testSigV4MatchesIndependentPythonFixtureAndEncodesNames() throws {
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let request = try S3MultipartRemote.signedRequest(connection: fixtureConnection, method: "PUT", key: "prefix/fólder/a+b name.txt", query: [("uploadId", "abc+/="), ("partNumber", "2")], body: Data("hello".utf8), date: date)
        XCTAssertEqual(request.url?.absoluteString, "https://fixture.r2.cloudflarestorage.com/fixture/prefix/f%C3%B3lder/a%2Bb%20name.txt?partNumber=2&uploadId=abc%2B%2F%3D")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=cc02cb258499f1ef39b8cb37749ae12d12c0627b2c9e4d254a95de6a597c63d9") == true)
    }

    func testXMLRejectsEntitiesAndParsesMultipartNamespace() throws {
        XCTAssertThrowsError(try S3XML(Data("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><x>&e;</x>".utf8)))
        let xml = try S3XML(Data("<ListPartsResult xmlns='http://s3.amazonaws.com/doc/2006-03-01/'><IsTruncated>false</IsTruncated><Part><PartNumber>1</PartNumber><ETag>&quot;abcd&quot;</ETag><Size>123</Size></Part></ListPartsResult>".utf8))
        XCTAssertEqual(xml.parts, [.init(number: 1, etag: "abcd", size: 123)])
        XCTAssertEqual(xml.values["IsTruncated"], "false")
    }

    @MainActor func testRememberedMissingRecordsDriveIsNotRecreatedAsEmptyQueue() async throws {
        let name = "direct-upload-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let missing = root.appendingPathComponent("disconnected-external-drive/CloudDrive Upload Records")
        preferences.set(missing.path, forKey: "directUploadRecordsFolder")
        let controller = DirectUploadController(defaultDirectory: root.appendingPathComponent("internal"), preferences: preferences)
        await controller.restoreIfNeeded()
        XCTAssertTrue(controller.loaded)
        XCTAssertTrue(controller.holdsDestination)
        XCTAssertTrue(controller.message.contains("unavailable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}

private actor SingleUploadStateRecorder {
    private var states: [UploadQueueState] = []
    func record(_ state: UploadQueueState) { states.append(state) }
    func values() -> [UploadQueueState] { states }
}
