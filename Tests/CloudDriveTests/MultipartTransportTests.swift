import XCTest
import CryptoKit
@testable import CloudDrive

/// Exercises real URLSession HTTP I/O against an independently signed loopback fixture.
final class MultipartTransportTests: XCTestCase {
    private var folder: URL!
    private var server: Process!
    private var remote: S3MultipartRemote!
    private var connection: Connection!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fixtures/multipart-s3-fixture.py")
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, folder.path]
        server.environment = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("port").path) {
            guard server.isRunning, Date() < deadline else {
                throw NSError(domain: "MultipartTransportFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Loopback fixture did not start within five seconds"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try String(contentsOf: folder.appendingPathComponent("port"), encoding: .utf8)
        connection = Connection(endpoint: "http://127.0.0.1:\(port)", bucket: "fixture", prefix: "prefix", accessKey: "fixture-access", secretKey: "fixture-secret")
        remote = S3MultipartRemote(connection: connection)
    }

    override func tearDown() async throws {
        remote?.close(); remote = nil
        if server?.isRunning == true {
            server.terminate()
            let deadline = Date().addingTimeInterval(2)
            while server.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func report() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("report.json"))) as! [String: Any]
    }

    private func createParts(key: String, count: Int = 3) async throws -> (UUID, String, [ConfirmedUploadPart], Data) {
        let jobID = UUID(), uploadID = try await remote.create(key: key, jobID: jobID)
        var parts: [ConfirmedUploadPart] = [], full = Data()
        for number in 1...count {
            let data = Data(repeating: UInt8(number), count: number * 127), digest = Insecure.MD5.hash(data: data).hex
            let tag = try await remote.putPart(key: key, uploadID: uploadID, number: number, data: data, md5: digest)
            parts.append(.init(number: number, etag: tag, md5: digest, size: Int64(data.count)))
            full.append(data)
        }
        return (jobID, uploadID, parts, full)
    }

    func testCompleteWireLifecycleAndIndependentSignatureVerification() async throws {
        let key = "prefix/fólder/cérémony a+b.mov"
        let before = try await remote.head(key: key); XCTAssertNil(before)
        let (job, uploadID, parts, full) = try await createParts(key: key)
        let listed = try await remote.list(key: key, uploadID: uploadID)
        XCTAssertEqual(listed, parts.map { .init(number: $0.number, etag: $0.etag, size: $0.size) })
        // The request encoder must sort parts even if its caller supplies completion order.
        try await remote.complete(key: key, uploadID: uploadID, parts: Array(parts.reversed()))
        let fetchedObject = try await remote.head(key: key)
        let object = try XCTUnwrap(fetchedObject)
        XCTAssertEqual(object.size, Int64(full.count)); XCTAssertEqual(object.jobID, job.uuidString)
        var binary = Data(); for part in parts { binary.append(Data(hex: part.md5)!) }
        XCTAssertEqual(object.etag, Insecure.MD5.hash(data: binary).hex + "-3")
        let report = try report()
        XCTAssertEqual(report["invalidSignatures"] as? Int, 0)
        XCTAssertEqual(report["validSignatures"] as? Int, 10)
        let events = try XCTUnwrap(report["events"] as? [[String: Any]])
        let markers = events.filter { $0["method"] as? String == "GET" }.compactMap { ($0["query"] as? [String: String])?["part-number-marker"] }
        XCTAssertEqual(markers, ["0", "1", "2"])
        let objects = try XCTUnwrap(report["objects"] as? [String: [String: Any]])
        XCTAssertEqual(objects[key]?["sha256"] as? String, SHA256.hash(data: full).hex)
    }

    func testAbortOnlyItsSessionAndTreatsAlreadyMissingAsSuccess() async throws {
        let (_, session, _, _) = try await createParts(key: "prefix/cancel", count: 1)
        try await remote.abort(key: "prefix/cancel", uploadID: session)
        try await remote.abort(key: "prefix/cancel", uploadID: session)
        do { _ = try await remote.list(key: "prefix/cancel", uploadID: session); XCTFail("Aborted upload must be absent") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .expired) }
        XCTAssertEqual(try report()["invalidSignatures"] as? Int, 0)
    }

    func testEmbeddedErrorInHTTP200IsNotCompletionSuccess() async throws {
        let (_, session, parts, _) = try await createParts(key: "prefix/embedded-error", count: 1)
        do { try await remote.complete(key: "prefix/embedded-error", uploadID: session, parts: parts); XCTFail("Embedded error must fail") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .invalidResponse) }
        let object = try await remote.head(key: "prefix/embedded-error"); XCTAssertNil(object)
    }

    func testRedirectIsDeniedWithoutSendingSignedRequestToTarget() async throws {
        do { _ = try await remote.head(key: "prefix/redirect"); XCTFail("Redirect must fail") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .http(307)) }
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events.contains { ($0["key"] as? String)?.hasSuffix("redirect-target") == true })
    }

    func testMalformedPartListAndPaginationLoopAreRejected() async throws {
        for key in ["prefix/malformed-list", "prefix/loop-pagination"] {
            do { _ = try await remote.list(key: key, uploadID: "fixture-session"); XCTFail("Malformed response must fail") }
            catch { XCTAssertEqual(error as? MultipartRemoteError, .invalidResponse) }
        }
    }

    func testOversizedResponseIsRejected() async throws {
        do { _ = try await remote.list(key: "prefix/oversized", uploadID: "fixture-session"); XCTFail("Response bound must hold") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .invalidResponse) }
    }

    func testServerETagMismatchFailsPartIntegrityCheck() async throws {
        let key = "prefix/bad-etag", session = try await remote.create(key: key, jobID: UUID())
        let data = Data("fixture".utf8), md5 = Insecure.MD5.hash(data: Data("fixture".utf8)).hex
        do { _ = try await remote.putPart(key: key, uploadID: session, number: 1, data: data, md5: md5); XCTFail("Wrong ETag must fail") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .checksumMismatch) }
    }

    func testEmptyObjectRetainsJobIdentityAndPreventsOverwrite() async throws {
        let job = UUID(), key = "prefix/empty"
        try await remote.putEmpty(key: key, jobID: job)
        let fetchedHead = try await remote.head(key: key)
        let head = try XCTUnwrap(fetchedHead)
        XCTAssertEqual(head.size, 0); XCTAssertEqual(head.jobID, job.uuidString)
        XCTAssertEqual(head.etag, Insecure.MD5.hash(data: Data()).hex)
        do { try await remote.putEmpty(key: key, jobID: UUID()); XCTFail("Existing object must not be overwritten") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .http(412)) }
        let still = try await remote.head(key: key); XCTAssertEqual(still?.jobID, job.uuidString)
    }

    func testSmallObjectSinglePUTChecksChecksumIdentityAndNoClobber() async throws {
        let id = UUID(), key = "prefix/small-file.wav", payload = Data(repeating: 37, count: 1024 * 1024 + 13)
        let digest = Insecure.MD5.hash(data: payload).hex
        try await remote.putObject(key: key, jobID: id, data: payload, md5: digest)
        let head = try await remote.head(key: key)
        XCTAssertEqual(head?.size, Int64(payload.count)); XCTAssertEqual(head?.jobID, id.uuidString); XCTAssertEqual(head?.etag, digest)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["method"] as? String }, ["PUT", "HEAD"])
        let objects = try XCTUnwrap(try report()["objects"] as? [String: [String: Any]])
        XCTAssertEqual(objects[key]?["sha256"] as? String, SHA256.hash(data: payload).hex)
        do { try await remote.putObject(key: key, jobID: UUID(), data: payload, md5: digest); XCTFail("Existing object must not be overwritten") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .http(412)) }
        XCTAssertEqual(try report()["invalidSignatures"] as? Int, 0)
    }

    func testRealURLSessionPUTPublishesCumulativePayloadTelemetry() async throws {
        XCTAssertEqual(remote.sentPayloadBytes(), 0)
        let payload = Data(repeating: 0x4b, count: 1_048_576 + 17)
        try await remote.putObject(key: "prefix/throughput-first.bin", jobID: UUID(), data: payload,
                                   md5: Insecure.MD5.hash(data: payload).hex)
        let first = remote.sentPayloadBytes()
        XCTAssertGreaterThanOrEqual(first, Int64(payload.count), "The URLSession bytes(for:) path must deliver didSendBodyData callbacks")
        let secondPayload = Data(repeating: 0x71, count: 2 * 1_048_576 + 31)
        try await remote.putObject(key: "prefix/throughput-second.bin", jobID: UUID(), data: secondPayload,
                                   md5: Insecure.MD5.hash(data: secondPayload).hex)
        XCTAssertGreaterThanOrEqual(remote.sentPayloadBytes() - first, Int64(secondPayload.count))
        let beforeHead = remote.sentPayloadBytes()
        _ = try await remote.head(key: "prefix/throughput-first.bin")
        XCTAssertEqual(remote.sentPayloadBytes(), beforeHead, "HEAD metadata must not inflate payload throughput")
        XCTAssertEqual(try report()["invalidSignatures"] as? Int, 0)
    }

    func testSmallObjectPUTRejectsBadChecksum() async throws {
        let payload = Data("unchanged payload".utf8)
        do {
            try await remote.putObject(key: "prefix/bad-small-checksum", jobID: UUID(), data: payload, md5: String(repeating: "0", count: 32))
            XCTFail("The server must reject the checksum")
        } catch { XCTAssertEqual(error as? MultipartRemoteError, .http(400)) }
    }

    func testIdentityEncodingPreservesJSONHeadSizeAndStrongETag() async throws {
        let key = "prefix/compressed-head", id = UUID(), data = Data("{\"cache\":true}".utf8)
        let digest = Insecure.MD5.hash(data: data).hex
        try await remote.putObject(key: key, jobID: id, data: data, md5: digest)
        var compressed = try S3MultipartRemote.signedRequest(connection: connection, method: "HEAD", key: key)
        XCTAssertEqual(compressed.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        compressed.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }
        let (_, response) = try await client.data(for: compressed)
        let encoded = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertNil(encoded.value(forHTTPHeaderField: "Content-Length"))
        XCTAssertTrue(encoded.value(forHTTPHeaderField: "ETag")?.hasPrefix("W/") == true)
        let object = try await remote.head(key: key)
        XCTAssertEqual(object?.size, Int64(data.count)); XCTAssertEqual(object?.etag, digest); XCTAssertEqual(object?.jobID, id.uuidString)
    }

    func testTransientPartFailureRetriesTheSameSessionAndPayload() async throws {
        let key = "prefix/retry-part", session = try await remote.create(key: key, jobID: UUID())
        let data = Data("retry this exact payload".utf8), digest = Insecure.MD5.hash(data: Data("retry this exact payload".utf8)).hex
        let tag = try await remote.putPart(key: key, uploadID: session, number: 1, data: data, md5: digest)
        XCTAssertEqual(tag, digest)
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        let puts = events.filter { $0["method"] as? String == "PUT" }
        XCTAssertEqual(puts.count, 2)
        XCTAssertTrue(puts.allSatisfy { ($0["query"] as? [String: String])?["uploadId"] == session })
        XCTAssertEqual(try report()["invalidSignatures"] as? Int, 0)
    }

    func testInitiationFailureIsNotRetriedIntoUntrackedSessions() async throws {
        do { _ = try await remote.create(key: "prefix/create-failure", jobID: UUID()); XCTFail("Creation failure must be surfaced") }
        catch { XCTAssertEqual(error as? MultipartRemoteError, .http(503)) }
        let events = try XCTUnwrap(try report()["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
    }
}
