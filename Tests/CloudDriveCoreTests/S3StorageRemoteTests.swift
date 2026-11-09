import XCTest
import CryptoKit
@testable import CloudDriveCore

private actor NativeMultipartReaderProbe {
    nonisolated let fifthStarted = XCTestExpectation(description: "Fifth native multipart reader started")
    private var first: CheckedContinuation<Void, Never>?
    private var released = false
    func read(_ range: Range<Int64>) async -> Data {
        if range.lowerBound == 0, !released { await withCheckedContinuation { first = $0 } }
        if range.lowerBound == 64 * 1024 * 1024 { fifthStarted.fulfill() }
        return Data(repeating: 0x53, count: range.count)
    }
    func firstIsBlocked() -> Bool { first != nil && !released }
    func releaseFirst() { released = true; first?.resume(); first = nil }
}

/// Native URLSession I/O with an independently authenticated Python S3 fixture.
/// Every test owns only synthetic loopback objects and disposable local receipts.
final class S3StorageRemoteTests: XCTestCase {
    private var directory: URL!
    private var server: Process!
    private var remote: S3StorageRemote!
    private var revision = 0

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-s3-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fixtures/namespace-s3-fixture.py")
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [script.path, directory.path]
        server.environment = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        let deadline = Date().addingTimeInterval(5), portFile = directory.appendingPathComponent("port")
        while !FileManager.default.fileExists(atPath: portFile.path) {
            guard server.isRunning, Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        remote = try S3StorageRemote(configuration: .init(endpoint: "http://127.0.0.1:"+port, bucket: "fixture", prefix: "prefix", accessKey: "fixture-access", secretKey: "fixture-secret", allowLoopbackFixture: true), multipartDirectory: directory.appendingPathComponent("receipts"))
    }
    override func tearDown() async throws {
        remote?.close(); remote = nil
        if server?.isRunning == true {
            server.terminate(); let deadline = Date().addingTimeInterval(2)
            while server.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func control(_ fields: [String: Any]) throws {
        revision += 1; var fields = fields; fields["revision"] = revision
        try JSONSerialization.data(withJSONObject: fields).write(to: directory.appendingPathComponent("control.json"), options: .atomic)
    }
    private func report() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.json"))) as! [String: Any]
    }
    private func failure<T>(_ action: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> StorageFailure? {
        do { _ = try await action(); XCTFail("Operation must fail closed", file: file, line: line); return nil }
        catch { return error as? StorageFailure }
    }
    private func payload() -> Data { Data(repeating: 0x17, count: 16*1024*1024) + Data(repeating: 0x48, count: 4*1024*1024) }
    private func upload(_ data: Data, key: String, id: UUID) async throws -> StorageObject {
        try await remote.upload(key: key, size: Int64(data.count), condition: .absent, operationID: id) { range in data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
    }
    func testUploadThroughputReportsSentRequestBodyBytes() async throws {
        XCTAssertEqual(remote.uploadBytesPerSecond(), 0)
        let key = "prefix/upload-throughput", bytes = Data(repeating: 0x53, count: 2 * 1024 * 1024)
        _ = try await remote.put(key: key, data: bytes, condition: .absent, operationID: UUID())
        // A single burst is averaged over three to four seconds.
        let rate = remote.uploadBytesPerSecond()
        XCTAssertGreaterThanOrEqual(rate, Double(bytes.count) / 4)
        XCTAssertLessThanOrEqual(rate, Double(bytes.count) / 3)
    }
    func testConditionalPutRangesAndListingUseIndependentSigV4WithEncodedNames() async throws {
        let key = "prefix/fólder/a + %20?.bin", data = Data("independently signed payload".utf8), id = UUID()
        let value = try await remote.put(key: key, data: data, condition: .absent, operationID: id)
        XCTAssertEqual(value.operationID, id); XCTAssertEqual(value.size, Int64(data.count))
        XCTAssertEqual(value.checksum, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let read = try await remote.read(key: key, range: 2..<12, validator: value.validator)
        XCTAssertEqual(read.data, data.subdata(in: 2..<12)); XCTAssertEqual(read.offset, 2); XCTAssertEqual(read.totalSize, Int64(data.count))
        let page = try await remote.list(prefix: "prefix/", cursor: nil, limit: 1)
        XCTAssertEqual(page.objects.map(\.key), [key]); XCTAssertNil(page.nextCursor)
        let report = try report(); XCTAssertEqual(report["invalidSignatures"] as? Int, 0)
        XCTAssertEqual(report["validSignatures"] as? Int, 4)
    }
    func testContentAddressedMetadataUsesOneRequestEachAndVerifiesDigest() async throws {
        let bytes = Data("immutable manifest page".utf8)
        let checksum = CoreFileIO.hash(bytes), key = "prefix/metadata/" + checksum
        try await remote.putContentAddressed(key: key, data: bytes, operationID: UUID())
        let received = try await remote.readContentAddressed(key: key, maximum: bytes.count, checksum: checksum)
        XCTAssertEqual(received, bytes)
        XCTAssertEqual(try report()["validSignatures"] as? Int, 2)

        let mismatch = await failure {
            try await self.remote.readContentAddressed(key: key, maximum: bytes.count, checksum: String(repeating: "0", count: 64))
        }
        XCTAssertEqual(mismatch, .integrity)
        let oversized = await failure {
            try await self.remote.readContentAddressed(key: key, maximum: bytes.count - 1, checksum: checksum)
        }
        XCTAssertEqual(oversized, .invalidResponse)
    }

    func testFailedPreconditionsNeverOverwriteExistingObject() async throws {
        let key = "prefix/conditional", first = Data("first".utf8), next = Data("newer".utf8)
        let original = try await remote.put(key: key, data: first, condition: .absent, operationID: UUID())
        let absent = await failure { try await self.remote.put(key: key, data: next, condition: .absent, operationID: UUID()) }
        XCTAssertEqual(absent, .conflict)
        let mismatch = await failure { try await self.remote.put(key: key, data: next, condition: .matches("\"wrong\""), operationID: UUID()) }
        XCTAssertEqual(mismatch, .conflict)
        let read = try await remote.read(key: key, range: 0..<Int64(first.count), validator: original.validator)
        XCTAssertEqual(read.data, first)
        let replacement = try await remote.put(key: key, data: next, condition: .matches(original.validator), operationID: UUID())
        XCTAssertNotEqual(replacement.validator, original.validator)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["ifNoneMatch"] as? String == "*" })
        XCTAssertTrue(events.contains { $0["ifMatch"] as? String == original.validator })
    }
    func testLostPutResponseRetainsReconcilableOperationIdentity() async throws {
        try control(["losePutResponse": true])
        let key = "prefix/uncertain-put", id = UUID(), data = Data("accepted before disconnect".utf8)
        let error = await failure { try await self.remote.put(key: key, data: data, condition: .absent, operationID: id) }
        XCTAssertTrue(error == .unknownOutcome || error == .conflict)
        let head = try await remote.head(key: key)
        let actual = try XCTUnwrap(head)
        XCTAssertEqual(actual.operationID, id); XCTAssertEqual(actual.size, Int64(data.count))
        let read = try await remote.read(key: key, range: 0..<Int64(data.count), validator: actual.validator)
        XCTAssertEqual(read.data, data)
    }
    func testStrictRangesRedirectAndPrefixEscapeAreRejected() async throws {
        for suffix in ["wrong-range", "wrong-etag", "truncated-range", "ignored-range"] {
            let key = "prefix/"+suffix
            let value = try await remote.put(key: key, data: Data("0123456789".utf8), condition: .absent, operationID: UUID())
            let error = await failure { try await self.remote.read(key: key, range: 2..<7, validator: value.validator) }
            XCTAssertNotNil(error)
        }
        let redirect = await failure { try await self.remote.head(key: "prefix/redirect") }
        XCTAssertEqual(redirect, .invalidResponse)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertFalse(events.contains { $0["key"] as? String == "prefix/redirect-target" })
        for key in ["outside/file", "prefix/../escape", "prefix/./escape"] {
            XCTAssertThrowsError(try remote.signedRequest(method: "GET", key: key))
        }
        try control(["listEscape": true])
        let list = await failure { try await self.remote.list(prefix: "prefix/", cursor: nil, limit: 10) }
        XCTAssertEqual(list, .invalidResponse)
    }
    func testUnknownCopyReconcilesWithoutOverwritingAnUnprovenDestination() async throws {
        let source = "prefix/source", destination = "prefix/copied", id = UUID(), data = Data("source bytes".utf8)
        let original = try await remote.put(key: source, data: data, condition: .absent, operationID: UUID())
        try control(["loseCopyResponse": true])
        _ = await failure { try await self.remote.copy(source: source, destination: destination, sourceValidator: original.validator, operationID: id) }
        let copied = try await remote.copy(source: source, destination: destination, sourceValidator: original.validator, operationID: id)
        XCTAssertEqual(copied.operationID, id); XCTAssertEqual(copied.checksum, original.checksum)
        let conflict = await failure { try await self.remote.copy(source: source, destination: destination, sourceValidator: original.validator, operationID: UUID()) }
        XCTAssertEqual(conflict, .conflict)
        let actual = try await remote.read(key: destination, range: 0..<Int64(data.count), validator: copied.validator)
        XCTAssertEqual(actual.data, data)
    }
    func testLostMultipartCompletionAndPublicationResponsesAreRecovered() async throws {
        for key in ["loseCompleteResponse", "loseCopyResponse"] {
            try control([key: true])
            let data = payload(), id = UUID(), destination = "prefix/"+key
            _ = await failure { try await self.upload(data, key: destination, id: id) }
            let uploaded = try await upload(data, key: destination, id: id)
            XCTAssertEqual(uploaded.size, Int64(data.count)); XCTAssertEqual(uploaded.operationID, id)
            let read = try await remote.read(key: destination, range: 1_000..<2_000, validator: uploaded.validator)
            XCTAssertEqual(read.data, data.subdata(in: 1_000..<2_000))
        }
        XCTAssertEqual(try report()["invalidSignatures"] as? Int, 0)
    }

    func testNativeMultipartRefillsPartsWhileFirstPartRemainsBlocked() async throws {
        let probe = NativeMultipartReaderProbe()
        let id = UUID(), key = "prefix/.clouddrive/v1/content/" + id.uuidString
        let job = Task { [remote] in
            try await remote!.uploadContent(keyHint: key, size: 80 * 1024 * 1024, operationID: id) { range in
                await probe.read(range)
            }
        }
        await fulfillment(of: [probe.fifthStarted], timeout: 10)
        let firstStillBlocked = await probe.firstIsBlocked()
        XCTAssertTrue(firstStillBlocked, "The fifth part must start before the slow first part completes")
        await probe.releaseFirst()
        let uploaded = try await job.value
        XCTAssertEqual(uploaded.size, 80 * 1024 * 1024)
        let data = try await remote.read(key: uploaded.key, range: 79 * 1024 * 1024..<80 * 1024 * 1024, validator: uploaded.validator)
        XCTAssertEqual(data.data, Data(repeating: 0x53, count: 1024 * 1024))
    }
    func testMissingRemoteConfirmedPartIsReuploadedBeforeCompletion() async throws {
        let data = payload(), id = UUID(), destination = "prefix/missing-part"
        try control(["failPartAlways": 2])
        _ = await failure { try await self.upload(data, key: destination, id: id) }
        try control(["dropPart": 1])
        let uploaded = try await upload(data, key: destination, id: id)
        XCTAssertEqual(uploaded.size, Int64(data.count))
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        let firstPartPuts = events.filter { $0["method"] as? String == "PUT" && ($0["query"] as? [String: String])?["partNumber"] == "1" }
        XCTAssertEqual(firstPartPuts.count, 2)
    }
    func testExpiredMultipartSessionRestartsWithNewDurableUploadIdentity() async throws {
        let data = payload(), id = UUID(), destination = "prefix/expired-session"
        try control(["failPartAlways": 2])
        _ = await failure { try await self.upload(data, key: destination, id: id) }
        try control(["expireUploads": true])
        let uploaded = try await upload(data, key: destination, id: id)
        XCTAssertEqual(uploaded.operationID, id); XCTAssertEqual(uploaded.size, Int64(data.count))
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        let creates = events.filter { $0["method"] as? String == "POST" && ($0["query"] as? [String: String])?["uploads"] != nil }
        XCTAssertEqual(creates.count, 2)
    }
    func testUnqualifiedAtomicDeleteNeverSendsAnUnconditionalDelete() async throws {
        let error = await failure { try await self.remote.delete(key: "prefix/file", validator: "\"etag\"") }
        XCTAssertEqual(error, .unsupported)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertTrue(events.isEmpty)
    }
    func testConditionalDeleteQualificationPersistsAndRemainsScopedToConnection() async throws {
        let key = "prefix/preserved-before-qualification"
        let original = try await remote.put(key: key, data: Data("preserve me".utf8), condition: .absent, operationID: UUID())
        try await remote.qualifyConditionalDelete()
        let qualified = try report()
        let events = try XCTUnwrap(qualified["events"] as? [[String: Any]])
        let probes = events.filter { ($0["key"] as? String)?.hasPrefix("prefix/.clouddrive/v1/qualification/") == true }
        XCTAssertEqual(probes.filter { $0["method"] as? String == "DELETE" }.count, 2)
        XCTAssertTrue(probes.allSatisfy { $0["key"] as? String != key })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipts/conditional-delete.json").path))
        let retained = try await remote.head(key: key)
        XCTAssertEqual(retained, original)

        remote.close()
        let port = try String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8)
        remote = try S3StorageRemote(configuration: .init(endpoint: "http://127.0.0.1:" + port, bucket: "fixture", prefix: "prefix", accessKey: "fixture-access", secretKey: "fixture-secret", allowLoopbackFixture: true), multipartDirectory: directory.appendingPathComponent("receipts"))
        let before = try XCTUnwrap(try report()["events"] as? [[String: Any]]).count
        try await remote.qualifyConditionalDelete()
        XCTAssertEqual(try XCTUnwrap(try report()["events"] as? [[String: Any]]).count, before, "Durable valid proof avoids repeating a synthetic mutation")
        try await remote.delete(key: key, validator: original.validator)
        let deleted = try await remote.head(key: key)
        XCTAssertNil(deleted)

        let another = try S3StorageRemote(configuration: .init(endpoint: "http://127.0.0.1:" + port, bucket: "fixture", prefix: "different-prefix", accessKey: "fixture-access", secretKey: "fixture-secret", allowLoopbackFixture: true), multipartDirectory: directory.appendingPathComponent("receipts"))
        defer { another.close() }
        let beforeForeign = try XCTUnwrap(try report()["events"] as? [[String: Any]]).count
        let error = await failure { try await another.delete(key: "different-prefix/protected", validator: original.validator) }
        XCTAssertEqual(error, .unsupported)
        XCTAssertEqual(try XCTUnwrap(try report()["events"] as? [[String: Any]]).count, beforeForeign)
    }
    func testProviderIgnoringDeletePreconditionCannotBecomeQualified() async throws {
        let key = "prefix/user-object", data = Data("unrelated bytes".utf8)
        let original = try await remote.put(key: key, data: data, condition: .absent, operationID: UUID())
        try control(["ignoreDeleteConditions": true])
        let error = await failure { try await self.remote.qualifyConditionalDelete() }
        XCTAssertEqual(error, .unsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipts/conditional-delete.json").path))
        let blocked = await failure { try await self.remote.delete(key: key, validator: original.validator) }
        XCTAssertEqual(blocked, .unsupported)
        let retained = try await remote.head(key: key)
        XCTAssertEqual(retained, original)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        let deletes = events.filter { $0["method"] as? String == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertTrue(deletes.allSatisfy { ($0["key"] as? String)?.hasPrefix("prefix/.clouddrive/v1/qualification/") == true })
    }
    func testLostMultipartCreationResponseRetainsOrphanWithoutOverwritingFinalBytes() async throws {
        try control(["loseCreateResponse": true])
        let data = payload(), id = UUID(), key = "prefix/create-response-lost"
        _ = await failure { try await self.upload(data, key: key, id: id) }
        let uploaded = try await upload(data, key: key, id: id)
        XCTAssertEqual(uploaded.operationID, id); XCTAssertEqual(uploaded.size, Int64(data.count))
        let report = try report(), uploads = try XCTUnwrap(report["uploads"] as? [String: Any])
        XCTAssertEqual(uploads.count, 1, "Uncertain older session must remain explicit orphan state")
        let objects = try XCTUnwrap(report["objects"] as? [String: [String: Any]])
        XCTAssertEqual(objects[key]?["sha256"] as? String, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    func testPartListingForAnotherObjectCannotAuthorizeReceiptReuse() async throws {
        let data = payload(), id = UUID(), key = "prefix/wrong-session"
        try control(["failPartAlways": 2])
        _ = await failure { try await self.upload(data, key: key, id: id) }
        try control(["wrongPartsIdentity": true])
        let error = await failure { try await self.upload(data, key: key, id: id) }
        XCTAssertEqual(error, .invalidResponse)
        let head = try await remote.head(key: key); XCTAssertNil(head)
    }
    func testCopyReplayCannotDiscardKnownSourceChecksumProof() async throws {
        let id = UUID(), source = "prefix/hashed-source", destination = "prefix/hashed-copy"
        let original = try await remote.put(key: source, data: Data("source bytes".utf8), condition: .absent, operationID: UUID())
        _ = try await remote.copy(source: source, destination: destination, sourceValidator: original.validator, operationID: id)
        try control(["removeChecksumKey": destination])
        let error = await failure { try await self.remote.copy(source: source, destination: destination, sourceValidator: original.validator, operationID: id) }
        XCTAssertNotNil(error)
    }

    func testOversizedUploadIsRejectedBeforeReaderOrArithmetic() async throws {
        let error = await failure {
            try await self.remote.upload(key: "prefix/oversized", size: Int64.max, condition: .absent, operationID: UUID()) { _ in
                XCTFail("Invalid size must be rejected before reading payload bytes")
                return Data()
            }
        }
        XCTAssertEqual(error, .invalidResponse)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertTrue(events.isEmpty)
    }
    func testOutOfRangeReceiptPartNumberCannotCrashOrAuthorizePayloadReuse() async throws {
        let data = payload(), id = UUID(), key = "prefix/corrupt-part-number"
        try control(["failPartAlways": 2])
        _ = await failure { try await self.upload(data, key: key, id: id) }
        let record = directory.appendingPathComponent("receipts/"+id.uuidString+".json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        var parts = try XCTUnwrap(state["parts"] as? [String: String])
        parts[String(Int.min)] = "\"untrusted\""; state["parts"] = parts
        try JSONSerialization.data(withJSONObject: state).write(to: record, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        try control([:])
        let uploaded = try await upload(data, key: key, id: id)
        XCTAssertEqual(uploaded.operationID, id); XCTAssertEqual(uploaded.size, Int64(data.count))
        let objects = try XCTUnwrap(try report()["objects"] as? [String: [String: Any]])
        XCTAssertEqual(objects[key]?["sha256"] as? String, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testLargeCompatibleCopiesAndMetadataChangesFailBeforeMutation() async throws {
        let key = "prefix/large-reported-object", bytes = Data("small synthetic payload".utf8)
        let original = try await remote.put(key: key, data: bytes, condition: .absent, operationID: UUID())
        try control(["headReportedSizes": [key: Int64(5) * 1024 * 1024 * 1024 + 1]])
        let before = try XCTUnwrap(try report()["events"] as? [[String: Any]]).count
        let copyError = await failure {
            try await self.remote.copy(source: key, destination: "prefix/new-large-destination", sourceValidator: original.validator, operationID: UUID())
        }
        XCTAssertEqual(copyError, .unsupported)
        let metadataError = await failure {
            try await self.remote.setModifiedAt(key: key, validator: original.validator, date: Date(timeIntervalSince1970: 1_700_000_000.25), operationID: UUID())
        }
        XCTAssertEqual(metadataError, .unsupported)
        let subsequent = Array(try XCTUnwrap(try report()["events"] as? [[String: Any]]).dropFirst(before))
        XCTAssertTrue(subsequent.allSatisfy { $0["method"] as? String == "HEAD" }, "Size refusal must precede copy PUT or multipart creation")
        let objects = try XCTUnwrap(try report()["objects"] as? [String: [String: Any]])
        XCTAssertEqual(Set(objects.keys), [key])
        XCTAssertEqual(objects[key]?["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try control([:])
        let preserved = try await remote.read(key: key, range: 0..<Int64(bytes.count), validator: original.validator)
        XCTAssertEqual(preserved.data, bytes)
    }

    func testLargeCompatibleUploadRefusesBeforeReadingOrCreatingMultipartState() async throws {
        let error = await failure {
            try await self.remote.upload(key: "prefix/too-large", size: Int64(5) * 1024 * 1024 * 1024 + 1,
                condition: .absent, operationID: UUID()) { _ in
                XCTFail("An unpublishable upload must not read source bytes")
                throw StorageFailure.integrity
            }
        }
        XCTAssertEqual(error, .unsupported)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("receipts").path).isEmpty)
    }

    func testManagedMultipartContentReferencesVerifiedImmutableKeyWithoutCopy() async throws {
        let bytes = payload(), id = UUID()
        let value = try await remote.uploadContent(keyHint: "prefix/.clouddrive/v1/content/" + id.uuidString,
            size: Int64(bytes.count), operationID: id) { range in bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
        XCTAssertTrue(value.key.hasPrefix("prefix/.clouddrive/v1/content/"))
        XCTAssertEqual(value.operationID, id)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertFalse(events.contains { $0["copyDestinationIfNoneMatch"] as? String == "*" })
        let objects = try XCTUnwrap(try report()["objects"] as? [String: [String: Any]])
        XCTAssertEqual(objects[value.key]?["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let replay = try await remote.uploadContent(keyHint: "prefix/.clouddrive/v1/content/" + id.uuidString,
            size: Int64(bytes.count), operationID: id) { _ in XCTFail("Verified immutable content must not be read again"); throw StorageFailure.integrity }
        XCTAssertEqual(replay, value)
    }
    func testConditionalMetadataChangePreservesBytesAndReconcilesLostReply() async throws {
        let key = "prefix/dated.bin", bytes = Data("unchanged contents".utf8)
        let original = try await remote.put(key: key, data: bytes, condition: .absent, operationID: UUID())
        let date = Date(timeIntervalSince1970: 1_700_000_000.25), id = UUID()
        try control(["loseCopyResponse": true])
        _ = await failure { try await self.remote.setModifiedAt(key: key, validator: original.validator, date: date, operationID: id) }
        let changed = try await remote.setModifiedAt(key: key, validator: original.validator, date: date, operationID: id)
        XCTAssertEqual(changed.modifiedAt, date)
        XCTAssertEqual(changed.checksum, original.checksum)
        let result = try await remote.read(key: key, range: 0..<Int64(bytes.count), validator: changed.validator)
        XCTAssertEqual(result.data, bytes)
        let failed = await failure { try await self.remote.setModifiedAt(key: key, validator: "wrong", date: Date(), operationID: UUID()) }
        XCTAssertEqual(failed, .conflict)
    }

}
