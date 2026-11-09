import XCTest
import CryptoKit
@testable import CloudDrive
import CloudDriveCore

private actor QualificationMemoryRemote: R2QualificationRemote {
    struct Entry { var object: StorageObject; var bytes: Data }
    var entries: [String: Entry] = [:]
    var deletes: [String] = []
    var qualifyCalled = false
    var maximumReaderBytes = 0
    let unsupportedDelete: Bool
    let unsupportedCopy: Bool
    let corruptRange: Bool
    let changeBeforeCleanup: Bool
    init(unsupportedCopy: Bool = false, unsupportedDelete: Bool = false, corruptRange: Bool = false, changeBeforeCleanup: Bool = false) {
        self.unsupportedDelete = unsupportedDelete
        self.unsupportedCopy = unsupportedCopy; self.corruptRange = corruptRange; self.changeBeforeCleanup = changeBeforeCleanup
    }
    func head(key: String) async throws -> StorageObject? { entries[key]?.object }
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject {
        guard key.hasPrefix("synthetic/run/") else { throw StorageFailure.integrity }
        switch condition {
        case .absent: if entries[key] != nil { throw StorageFailure.conflict }
        case .matches(let tag): if entries[key]?.object.validator != tag { throw StorageFailure.conflict }
        case .unconditional: throw StorageFailure.integrity
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let object = StorageObject(key: key, size: Int64(data.count), validator: "\""+digest+"\"", checksum: digest, operationID: operationID)
        entries[key] = Entry(object: object, bytes: data); return object
    }
    func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange {
        guard let entry = entries[key], entry.object.validator == validator else { throw StorageFailure.conflict }
        var bytes = entry.bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        if corruptRange && !bytes.isEmpty { bytes[0] ^= 0xff }
        if changeBeforeCleanup && key.hasSuffix("/multipart.bin") && range.upperBound == entry.object.size {
            entries["synthetic/run/small.bin"]?.object.validator = "foreign-generation"
        }
        return StorageRange(data: bytes, offset: range.lowerBound, totalSize: entry.object.size, validator: validator)
    }
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) async throws -> StorageObject {
        if unsupportedCopy { throw StorageFailure.unsupported }
        guard let source = entries[source], source.object.validator == sourceValidator else { throw StorageFailure.conflict }
        return try await put(key: destination, data: source.bytes, condition: .absent, operationID: operationID)
    }
    func delete(key: String, validator: String) async throws {
        guard qualifyCalled, entries[key]?.object.validator == validator else { throw StorageFailure.conflict }
        deletes.append(key); entries.removeValue(forKey: key)
    }
    func list(prefix: String, cursor: String?, limit: Int) async throws -> StoragePage {
        guard prefix == "synthetic/run/" else { throw StorageFailure.integrity }
        return StoragePage(objects: entries.values.map(\.object).filter { $0.key.hasPrefix(prefix) })
    }
    func qualifyConditionalDelete() async throws {
        if unsupportedDelete { throw StorageFailure.unsupported }
        qualifyCalled = true
    }
    func upload(key: String, size: Int64, condition: StorageCondition, operationID: UUID, reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        var bytes = Data(), offset: Int64 = 0
        while offset < size {
            let range = offset..<min(size, offset + 16 * 1024 * 1024)
            let chunk = try await reader(range); maximumReaderBytes = max(maximumReaderBytes, chunk.count)
            bytes.append(chunk); offset = range.upperBound
        }
        return try await put(key: key, data: bytes, condition: condition, operationID: operationID)
    }
    func counts() -> (objects: Int, deletes: Int, maximumRead: Int) { (entries.count, deletes.count, maximumReaderBytes) }
}

final class R2QualificationTests: XCTestCase {
    private func run(_ remote: QualificationMemoryRemote) async -> R2QualificationReport {
        await R2QualificationScenario(remote: remote, prefix: "synthetic/run", runID: UUID(), checkpoint: { _ in }).run()
    }
    func testCompleteRunVerifiesBytesAndCleansOnlyItsManifest() async throws {
        let remote = QualificationMemoryRemote(), report = await run(remote)
        XCTAssertEqual(report.state, "passed"); XCTAssertEqual(report.steps.count, 6)
        XCTAssertTrue(report.retainedObjects.isEmpty); XCTAssertEqual(report.verifiedSHA256.count, 3)
        let counts = await remote.counts(); XCTAssertEqual(counts.objects, 0); XCTAssertEqual(counts.deletes, 3)
        XCTAssertLessThanOrEqual(counts.maximumRead, 16 * 1024 * 1024)
        let encoded = try JSONEncoder().encode(report), text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic/run")); XCTAssertFalse(text.contains("endpoint")); XCTAssertFalse(text.contains("secretKey"))
    }
    func testUnsupportedCopyStillRunsMultipartButPreservesAllSyntheticObjects() async {
        let remote = QualificationMemoryRemote(unsupportedCopy: true), report = await run(remote)
        XCTAssertEqual(report.state, "incomplete")
        XCTAssertEqual(report.steps.first(where: { $0.name == "conditional-copy" })?.state, "unsupported")
        XCTAssertEqual(report.steps.first(where: { $0.name == "multipart-and-full-readback" })?.state, "passed")
        let counts = await remote.counts(); XCTAssertEqual(counts.objects, 2); XCTAssertEqual(counts.deletes, 0)
    }
    func testUnsupportedDeleteStillRunsMultipartWithoutDeletingAnyObject() async {
        let remote = QualificationMemoryRemote(unsupportedDelete: true), report = await run(remote)
        XCTAssertEqual(report.state, "incomplete")
        XCTAssertEqual(report.steps.first(where: { $0.name == "conditional-delete-capability" })?.state, "unsupported")
        XCTAssertEqual(report.steps.first(where: { $0.name == "multipart-and-full-readback" })?.state, "passed")
        XCTAssertEqual(report.steps.last?.state, "retained")
        let counts = await remote.counts(); XCTAssertEqual(counts.objects, 3); XCTAssertEqual(counts.deletes, 0)
    }
    func testBadBytesFailWithoutCleanup() async {
        let remote = QualificationMemoryRemote(corruptRange: true), report = await run(remote)
        XCTAssertEqual(report.state, "failed"); XCTAssertEqual(report.steps.last?.diagnostic, "integrity-check-failed")
        let counts = await remote.counts(); XCTAssertEqual(counts.objects, 1); XCTAssertEqual(counts.deletes, 0)
    }
    func testForeignGenerationBeforeCleanupPreventsEveryDelete() async {
        let remote = QualificationMemoryRemote(changeBeforeCleanup: true), report = await run(remote)
        XCTAssertEqual(report.state, "failed"); XCTAssertEqual(report.steps.last?.name, "cleanup")
        let counts = await remote.counts(); XCTAssertEqual(counts.objects, 3); XCTAssertEqual(counts.deletes, 0)
    }
    func testPayloadCanBeReplayedAcrossDifferentRangesAndRejectsUnboundedRead() throws {
        let whole = try R2QualificationScenario.payload(65_000..<132_000, salt: 43)
        let split = try R2QualificationScenario.payload(65_000..<100_000, salt: 43) + R2QualificationScenario.payload(100_000..<132_000, salt: 43)
        XCTAssertEqual(whole, split)
        XCTAssertThrowsError(try R2QualificationScenario.payload(0..<R2QualificationScenario.multipartSize))
    }
}
