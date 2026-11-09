import XCTest
import CryptoKit
import Darwin
@testable import CloudDrive

/// This fixture keeps only metadata for the logically uploaded 400 GB. It does not transfer or allocate 400 GB.
private actor LargeResumeRemote: MultipartRemote {
    private let jobID: UUID
    private let expectedSize: Int64
    private let expectedETag: String
    private let expectedMissing: [Int: (size: Int64, md5: String)]
    private var parts: [Int: RemoteUploadPart]
    private var published: RemoteUploadObject?
    private var sent: [Int] = []
    private var createCount = 0
    private var transferredBytes: Int64 = 0

    init(job: DirectUploadJob, missing: [Int: (size: Int64, md5: String)], expectedETag: String) {
        self.jobID = job.id; self.expectedSize = job.source.size; self.expectedETag = expectedETag
        self.expectedMissing = missing
        self.parts = Dictionary(uniqueKeysWithValues: job.parts.map {
            ($0.number, RemoteUploadPart(number: $0.number, etag: $0.etag, size: $0.size))
        })
    }
    func head(key: String) async throws -> RemoteUploadObject? { published }
    func create(key: String, jobID: UUID) async throws -> String {
        createCount += 1
        throw DirectUploadFailure.message("A recovered upload must reuse its original upload ID.")
    }
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart] {
        guard uploadID == "persisted-400GB-session" else { throw MultipartRemoteError.invalidResponse }
        return parts.values.sorted { $0.number < $1.number }
    }
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String {
        guard uploadID == "persisted-400GB-session", let expected = expectedMissing[number],
              Int64(data.count) == expected.size, md5 == expected.md5,
              Insecure.MD5.hash(data: data).hex == expected.md5 else {
            throw MultipartRemoteError.checksumMismatch
        }
        sent.append(number); transferredBytes += Int64(data.count)
        parts[number] = .init(number: number, etag: md5, size: Int64(data.count))
        return md5
    }
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws {
        guard parts.count == 5961, self.parts.count == 5961 else { throw MultipartRemoteError.invalidResponse }
        var digestBytes = Data(), total: Int64 = 0
        for part in parts.sorted(by: { $0.number < $1.number }) {
            guard let remote = self.parts[part.number], remote.etag == part.etag, remote.size == part.size,
                  let binary = Data(hex: part.md5) else { throw MultipartRemoteError.checksumMismatch }
            digestBytes.append(binary); total += part.size
        }
        let checksum = Insecure.MD5.hash(data: digestBytes).hex + "-5961"
        guard total == expectedSize, checksum == expectedETag else { throw MultipartRemoteError.checksumMismatch }
        published = .init(size: total, etag: checksum, jobID: jobID.uuidString)
    }
    func putEmpty(key: String, jobID: UUID) async throws { throw MultipartRemoteError.invalidResponse }
    func abort(key: String, uploadID: String) async throws { throw MultipartRemoteError.invalidResponse }
    func metrics() -> (sent: [Int], creates: Int, bytes: Int64) { (sent.sorted(), createCount, transferredBytes) }
}

final class LargeMultipartResumeTests: XCTestCase {
    func testLogical400GBUploadRecovers5959PartsAndReadsOnlyHighOffsetTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logical-400GB-resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("400GB-video.mov"), records = root.appendingPathComponent("records")
        let size: Int64 = 400_000_000_000, partSize: Int64 = 64 * 1_048_576
        let totalParts = Int((size + partSize - 1) / partSize)
        XCTAssertEqual(totalParts, 5961)
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(size))
        // Distinct bytes in the two missing ranges prove the engine seeks to the high offsets rather than rereading offset zero.
        try file.seek(toOffset: UInt64(5959 * partSize)); try file.write(contentsOf: Data([0xa7]))
        try file.seek(toOffset: UInt64(5960 * partSize)); try file.write(contentsOf: Data([0x5c]))
        try file.synchronize(); try file.close()
        var sourceStat = stat()
        XCTAssertEqual(lstat(source.path, &sourceStat), 0)
        XCTAssertEqual(sourceStat.st_size, size)
        XCTAssertLessThan(Int64(sourceStat.st_blocks) * 512, 1_048_576, "The source fixture must remain sparse, never allocate 400 GB")

        let connection = Connection(endpoint: "https://large-fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "prefix", accessKey: "synthetic-access", secretKey: "synthetic-secret")
        var job = DirectUploadJob(batchID: UUID(), sourcePath: source.path, source: try UploadSourceIdentity.capture(source), destination: connection.fingerprint,
                                  key: "prefix/400GB-video.mov", partSize: partSize)
        job.uploadID = "persisted-400GB-session"; job.status = .paused; job.phase = .transferring
        let tailSize = size - 5960 * partSize
        // Cache only three digest strings. All prior full parts represent sparse zero ranges.
        let digests: (zero: String, penultimate: String, last: String) = {
            var full = Data(repeating: 0, count: Int(partSize))
            let zero = Insecure.MD5.hash(data: full).hex
            full[0] = 0xa7
            let penultimate = Insecure.MD5.hash(data: full).hex
            var last = Data(repeating: 0, count: Int(tailSize)); last[0] = 0x5c
            return (zero, penultimate, Insecure.MD5.hash(data: last).hex)
        }()
        job.parts = (1...5959).map { .init(number: $0, etag: digests.zero, md5: digests.zero, size: partSize) }
        let initialSavedBytes = job.parts.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertGreaterThan(initialSavedBytes, 399_000_000_000)
        do {
            let store = try UploadQueueStore(directory: records)
            try store.insert([job])
            try store.reconcileParts(job)
        }
        var completeLedger = job
        completeLedger.parts += [
            .init(number: 5960, etag: digests.penultimate, md5: digests.penultimate, size: partSize),
            .init(number: 5961, etag: digests.last, md5: digests.last, size: tailSize)
        ]
        let expectedETag = try XCTUnwrap(completeLedger.expectedETag)
        let remote = LargeResumeRemote(job: job, missing: [5960: (partSize, digests.penultimate), 5961: (tailSize, digests.last)], expectedETag: expectedETag)
        let recoveredEngine = DirectUploadEngine()
        let recovered = try await recoveredEngine.open(directory: records, recoverExisting: true)
        XCTAssertEqual(recovered[0].parts.count, 5959)
        XCTAssertEqual(recovered[0].completedBytes, initialSavedBytes)
        try await recoveredEngine.run(id: job.id, remote: remote, destination: connection.fingerprint) { _ in }
        let snapshot = await recoveredEngine.snapshot(), metrics = await remote.metrics()
        let receipt = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(metrics.sent, [5960, 5961]); XCTAssertEqual(metrics.creates, 0)
        XCTAssertEqual(metrics.bytes, size - initialSavedBytes)
        XCTAssertLessThan(metrics.bytes, 128 * 1_048_576)
        XCTAssertEqual(receipt.status, .uploaded); XCTAssertEqual(receipt.phase, .complete)
        XCTAssertEqual(receipt.completedBytes, size); XCTAssertEqual(receipt.expectedETag, expectedETag)
        XCTAssertNotNil(receipt.verifiedAt)
        let recordsBytes = try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: [.fileAllocatedSizeKey]).reduce(Int64(0)) {
            $0 + Int64(try $1.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize ?? 0)
        }
        XCTAssertLessThan(recordsBytes, 8 * 1_048_576, "Resume records must be orders of magnitude smaller than the logical payload")
    }
}
