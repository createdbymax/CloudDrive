import XCTest
import CryptoKit
@testable import CloudDrive

private let smallObjectConnection = Connection(endpoint: "https://small-object-fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "prefix", accessKey: "synthetic-access", secretKey: "synthetic-secret")

/// Synthetic metadata-only remote: latency can be injected without any network or provider access.
private actor SmallObjectFixture: SingleObjectRemote {
    private var calls: [String] = []
    private var objects: [String: RemoteUploadObject] = [:]
    private var jobID: UUID?
    private var chunks: [Int: (size: Int64, md5: String)] = [:]
    private var losePutResponse = false
    private var failPut = false
    private let latency: Duration
    init(latency: Duration = .zero, jobID: UUID? = nil) { self.latency = latency; self.jobID = jobID }
    func configure(losePutResponse: Bool = false, failPut: Bool = false) {
        self.losePutResponse = losePutResponse; self.failPut = failPut
    }
    func trace() -> [String] { calls }
    private func operation(_ name: String) async throws {
        calls.append(name)
        if latency > .zero { try await Task.sleep(for: latency) }
    }
    func head(key: String) async throws -> RemoteUploadObject? { try await operation("head"); return objects[key] }
    func create(key: String, jobID: UUID) async throws -> String {
        try await operation("create"); self.jobID = jobID; chunks = [:]; return "small-fixture-session"
    }
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart] {
        try await operation("list")
        return chunks.map { .init(number: $0.key, etag: $0.value.md5, size: $0.value.size) }
    }
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String {
        try await operation("part")
        guard Insecure.MD5.hash(data: data).hex == md5 else { throw MultipartRemoteError.checksumMismatch }
        chunks[number] = (Int64(data.count), md5); return md5
    }
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws {
        try await operation("complete")
        var digests = Data(), size: Int64 = 0
        for part in parts.sorted(by: { $0.number < $1.number }) {
            guard let remote = chunks[part.number], remote.size == part.size, remote.md5 == part.md5,
                  let bytes = Data(hex: part.md5) else { throw MultipartRemoteError.checksumMismatch }
            digests.append(bytes); size += part.size
        }
        objects[key] = .init(size: size, etag: Insecure.MD5.hash(data: digests).hex + "-\(parts.count)", jobID: jobID?.uuidString)
    }
    func putObject(key: String, jobID: UUID, data: Data, md5: String) async throws {
        try await operation("put")
        guard Insecure.MD5.hash(data: data).hex == md5 else { throw MultipartRemoteError.checksumMismatch }
        if failPut { throw MultipartRemoteError.http(503) }
        objects[key] = .init(size: Int64(data.count), etag: md5, jobID: jobID.uuidString)
        if losePutResponse { throw URLError(.networkConnectionLost) }
    }
    func putEmpty(key: String, jobID: UUID) async throws {
        try await operation("empty")
        objects[key] = .init(size: 0, etag: Insecure.MD5.hash(data: Data()).hex, jobID: jobID.uuidString)
    }
    func abort(key: String, uploadID: String) async throws { try await operation("abort"); chunks = [:] }
}

/// Hides only SingleObjectRemote capability, so the same remote can exercise the existing multipart route.
private struct MultipartOnlyFixture: MultipartRemote {
    let base: SmallObjectFixture
    func head(key: String) async throws -> RemoteUploadObject? { try await base.head(key: key) }
    func create(key: String, jobID: UUID) async throws -> String { try await base.create(key: key, jobID: jobID) }
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart] { try await base.list(key: key, uploadID: uploadID) }
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String {
        try await base.putPart(key: key, uploadID: uploadID, number: number, data: data, md5: md5)
    }
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws { try await base.complete(key: key, uploadID: uploadID, parts: parts) }
    func putEmpty(key: String, jobID: UUID) async throws { try await base.putEmpty(key: key, jobID: jobID) }
    func abort(key: String, uploadID: String) async throws { try await base.abort(key: key, uploadID: uploadID) }
}

final class SmallObjectUploadTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("small-object-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func job(size: Int = 64 * 1024) throws -> DirectUploadJob {
        let file = root.appendingPathComponent(UUID().uuidString + ".bin")
        try Data(repeating: 0x63, count: size).write(to: file)
        return DirectUploadJob(batchID: UUID(), sourcePath: file.path, source: try UploadSourceIdentity.capture(file), destination: smallObjectConnection.fingerprint,
                               key: "prefix/" + file.lastPathComponent, partSize: 64 * 1_048_576)
    }
    private func seed(_ jobs: [DirectUploadJob], at directory: URL) throws { try UploadQueueStore(directory: directory).insert(jobs) }

    func testSmallFileUsesOnePutAndVerifiedSingleObjectChecksum() async throws {
        let job = try job(), records = root.appendingPathComponent("records")
        try seed([job], at: records)
        let engine = DirectUploadEngine(), remote = SmallObjectFixture(); _ = try await engine.open(directory: records)
        try await engine.run(id: job.id, remote: remote, destination: smallObjectConnection.fingerprint) { _ in }
        let calls = await remote.trace(), snapshot = await engine.snapshot()
        XCTAssertEqual(calls, ["head", "put", "head"])
        let receipt = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(receipt.status, .uploaded); XCTAssertEqual(receipt.phase, .complete)
        XCTAssertNotNil(receipt.singlePutMD5); XCTAssertEqual(receipt.expectedETag, receipt.singlePutMD5)
        XCTAssertTrue(receipt.parts.isEmpty); XCTAssertNil(receipt.uploadID); XCTAssertNotNil(receipt.verifiedAt)
    }

    func testLostPutResponseRecoversAfterRestartWithoutOriginalSource() async throws {
        let job = try job(), records = root.appendingPathComponent("records")
        try seed([job], at: records)
        let first = DirectUploadEngine(), remote = SmallObjectFixture(); _ = try await first.open(directory: records)
        await remote.configure(losePutResponse: true)
        do { try await first.run(id: job.id, remote: remote, destination: smallObjectConnection.fingerprint) { _ in }; XCTFail("Expected ambiguous response") }
        catch is URLError { }
        let interrupted = await first.snapshot()
        XCTAssertEqual(interrupted[0].phase, .completing); XCTAssertNotNil(interrupted[0].singlePutMD5)
        await first.closeForTesting()
        try FileManager.default.removeItem(atPath: job.sourcePath)
        let restarted = DirectUploadEngine(); _ = try await restarted.open(directory: records)
        try await restarted.run(id: job.id, remote: remote, destination: smallObjectConnection.fingerprint) { _ in }
        let calls = await remote.trace(), receipt = await restarted.snapshot()
        XCTAssertEqual(calls.filter { $0 == "put" }.count, 1)
        XCTAssertEqual(receipt[0].status, .uploaded); XCTAssertNotNil(receipt[0].verifiedAt)
    }

    func testAlreadyStartedSmallMultipartSessionKeepsItsPartsProtocol() async throws {
        var job = try job(); job.uploadID = "existing-session"; job.phase = .transferring
        let records = root.appendingPathComponent("records"); try seed([job], at: records)
        let engine = DirectUploadEngine(), remote = SmallObjectFixture(jobID: job.id); _ = try await engine.open(directory: records)
        try await engine.run(id: job.id, remote: remote, destination: smallObjectConnection.fingerprint) { _ in }
        let calls = await remote.trace(), receipt = await engine.snapshot()
        XCTAssertFalse(calls.contains("put")); XCTAssertFalse(calls.contains("create"))
        XCTAssertTrue(calls.contains("list")); XCTAssertTrue(calls.contains("part")); XCTAssertTrue(calls.contains("complete"))
        XCTAssertEqual(receipt[0].status, .uploaded); XCTAssertNil(receipt[0].singlePutMD5)
        XCTAssertTrue(receipt[0].expectedETag?.hasSuffix("-1") == true)
    }

    func testChangedSourceCannotEnterSingleObjectPut() async throws {
        let job = try job(), records = root.appendingPathComponent("records"); try seed([job], at: records)
        try Data(repeating: 0x2a, count: Int(job.source.size) + 1).write(to: URL(fileURLWithPath: job.sourcePath))
        let engine = DirectUploadEngine(), remote = SmallObjectFixture(); _ = try await engine.open(directory: records)
        do { try await engine.run(id: job.id, remote: remote, destination: smallObjectConnection.fingerprint) { _ in }; XCTFail("Changed source must fail") }
        catch is DirectUploadFailure { }
        let calls = await remote.trace(), snapshot = await engine.snapshot()
        XCTAssertFalse(calls.contains("put")); XCTAssertNil(snapshot[0].singlePutMD5); XCTAssertNil(snapshot[0].verifiedAt)
    }

    func testFailedPutRetainsDurableIntentAndCanBeRetried() async throws {
        let job = try job(), records = root.appendingPathComponent("records"); try seed([job], at: records)
        let engine = DirectUploadEngine(), remote = SmallObjectFixture(); _ = try await engine.open(directory: records)
        await remote.configure(failPut: true)
        do { try await engine.run(id: job.id, remote: remote, destination: smallObjectConnection.fingerprint) { _ in }; XCTFail("Expected HTTP failure") }
        catch MultipartRemoteError.http(503) { }
        let interrupted = await engine.snapshot()
        XCTAssertEqual(interrupted[0].status, .attention); XCTAssertEqual(interrupted[0].phase, .completing)
        XCTAssertNotNil(interrupted[0].singlePutMD5); XCTAssertNil(interrupted[0].verifiedAt)
        await engine.closeForTesting()
        let reopened = DirectUploadEngine(); _ = try await reopened.open(directory: records)
        await remote.configure()
        try await reopened.run(id: job.id, remote: remote, destination: smallObjectConnection.fingerprint) { _ in }
        let receipt = await reopened.snapshot(), calls = await remote.trace()
        XCTAssertEqual(receipt[0].status, .uploaded); XCTAssertEqual(calls.filter { $0 == "put" }.count, 2)
        XCTAssertFalse(calls.contains("create"))
    }

    func testEightMiBUsesSinglePutAndLargerFileUsesMultipart() async throws {
        let boundary = try job(size: 8 * 1_048_576), larger = try job(size: 8 * 1_048_576 + 1)
        let records = root.appendingPathComponent("records"); try seed([boundary, larger], at: records)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        let small = SmallObjectFixture(), large = SmallObjectFixture()
        try await engine.run(id: boundary.id, remote: small, destination: smallObjectConnection.fingerprint) { _ in }
        try await engine.run(id: larger.id, remote: large, destination: smallObjectConnection.fingerprint) { _ in }
        let smallCalls = await small.trace(), largeCalls = await large.trace()
        XCTAssertTrue(smallCalls.contains("put")); XCTAssertFalse(smallCalls.contains("create"))
        XCTAssertFalse(largeCalls.contains("put")); XCTAssertTrue(largeCalls.contains("create")); XCTAssertTrue(largeCalls.contains("complete"))
    }

    func testSyntheticRequestLatencyBenchmarkUsesFewerRoundTrips() async throws {
        let jobs = try (0..<6).map { _ in try job(size: 4 * 1024) }
        let singleRecords = root.appendingPathComponent("single-records"), multiRecords = root.appendingPathComponent("multipart-records")
        try seed(jobs, at: singleRecords); try seed(jobs, at: multiRecords)
        let single = DirectUploadEngine(), multi = DirectUploadEngine()
        _ = try await single.open(directory: singleRecords); _ = try await multi.open(directory: multiRecords)
        let fast = SmallObjectFixture(latency: .milliseconds(10)), slow = SmallObjectFixture(latency: .milliseconds(10))
        let fastStart = Date()
        for job in jobs { try await single.run(id: job.id, remote: fast, destination: smallObjectConnection.fingerprint) { _ in } }
        let fastDuration = Date().timeIntervalSince(fastStart), slowStart = Date()
        for job in jobs { try await multi.run(id: job.id, remote: MultipartOnlyFixture(base: slow), destination: smallObjectConnection.fingerprint) { _ in } }
        let slowDuration = Date().timeIntervalSince(slowStart)
        let fastCalls = await fast.trace(), slowCalls = await slow.trace()
        XCTAssertEqual(fastCalls.count, jobs.count * 3)
        XCTAssertLessThan(fastCalls.count, slowCalls.count)
        XCTAssertEqual(fastCalls.filter { $0 == "put" }.count, jobs.count)
        XCTAssertEqual(slowCalls.filter { $0 == "part" }.count, jobs.count)
        // Request-count assertions are deterministic; elapsed measurements are evidence, not timing-sensitive test gates.
        print(String(format: "Synthetic 10ms RTT, %d small files: single PUT %d requests / %.3fs; multipart %d requests / %.3fs", jobs.count, fastCalls.count, fastDuration, slowCalls.count, slowDuration))
    }
}
