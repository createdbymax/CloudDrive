import XCTest
@testable import CloudDrive

final class InventoryTransportTests: XCTestCase {
    private var folder: URL!
    private var server: Process!
    private var remote: S3InventoryRemote!
    private var connection: Connection!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fixtures/inventory-s3-fixture.py")
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [script.path,folder.path]
        server.environment = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice; try server.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("port").path) {
            guard server.isRunning, Date() < deadline else { throw CatalogFailure.invalidInventory }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try String(contentsOf: folder.appendingPathComponent("port"), encoding: .utf8)
        connection = Connection(endpoint: "http://127.0.0.1:\(port)", bucket: "fixture", prefix: "prefix", accessKey: "fixture-access", secretKey: "fixture-secret")
        remote = S3InventoryRemote(connection: connection, validateEndpoint: false)
    }
    override func tearDown() async throws {
        remote?.close(); remote = nil
        if server?.isRunning == true {
            server.terminate(); let deadline = Date().addingTimeInterval(2)
            while server.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            if server.isRunning { kill(server.processIdentifier,SIGKILL) }
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
    private func report() throws -> [String:Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("report.json"))) as! [String:Any] }
    func testReadOnlyWireScanSignaturePaginationAndOfflineSearch() async throws {
        let directory = folder.appendingPathComponent("catalog")
        let store = CatalogStore(directory: directory, fingerprint: "fixture", prefix: "prefix")
        try await CatalogIndexer.scan(store: store, remote: remote, fresh: true)
        remote.close(); remote = nil
        let before = try report()
        let results = try await store.search(CatalogQuery(text: "voc"))
        XCTAssertEqual(results.first?.key, "prefix/Album/Vócals +%2F.wav")
        XCTAssertEqual(results.first?.etag, "\"opaque\"")
        XCTAssertEqual(results.first?.size, 42)
        let summary = try await store.summary(); XCTAssertEqual(summary.count,3); XCTAssertNotNil(summary.lastCompleted)
        let events = try XCTUnwrap(before["events"] as? [[String:Any]])
        XCTAssertEqual(events.count,2); XCTAssertEqual(before["validSignatures"] as? Int,2); XCTAssertEqual(before["invalidSignatures"] as? Int,0)
        XCTAssertTrue(events.allSatisfy { $0["method"] as? String == "GET" && $0["path"] as? String == "/fixture" })
        XCTAssertEqual((events.last?["query"] as? [String:String])?["continuation-token"], "opaque+/% token")
        XCTAssertEqual((try report()["events"] as? [[String:Any]])?.count,2, "Local search must not send requests")
    }
    func testTargetedHeadAndScopedListingUseExactMetadataWithoutPayloadReads() async throws {
        let object = try await remote.head(key:"prefix/present.wav")
        XCTAssertEqual(object?.size,42); XCTAssertEqual(object?.etag,"\"opaque\"")
        let absent = try await remote.head(key:"prefix/missing"); XCTAssertNil(absent)
        let scoped = try await remote.list(scope:"prefix/Album/",token:nil)
        XCTAssertEqual(scoped.objects.map(\.key),["prefix/Album/Vócals +%2F.wav"]); XCTAssertNil(scoped.nextToken)
        for key in ["prefix/denied","prefix/redirect","prefix/malformed-head"] {
            do { _ = try await remote.head(key:key); XCTFail("Invalid/error HEAD is not absence") } catch {}
        }
        let events = try XCTUnwrap(try report()["events"] as? [[String:Any]])
        XCTAssertEqual(events.count,6)
        XCTAssertEqual(events.filter { $0["method"] as? String == "GET" }.count,1)
        XCTAssertEqual(try report()["invalidSignatures"] as? Int,0)
    }
    func testHeadErrorsAndRedirectAreNotAbsence() async throws {
        let missing = try await remote.isMissing(key: "prefix/missing"); XCTAssertTrue(missing)
        let present = try await remote.isMissing(key: "prefix/present"); XCTAssertFalse(present)
        for key in ["prefix/denied", "prefix/redirect"] {
            do { _ = try await remote.isMissing(key:key); XCTFail("Must not treat error as absence") } catch {}
        }
        let report = try report(), events = try XCTUnwrap(report["events"] as? [[String:Any]])
        XCTAssertEqual(events.count,4); XCTAssertEqual(report["invalidSignatures"] as? Int,0)
        XCTAssertFalse(events.contains { ($0["path"] as? String)?.contains("redirect-target") == true })
    }
    func testProductionTransportRejectsNonR2EndpointBeforeRequest() async throws {
        let production = S3InventoryRemote(connection: connection); defer { production.close() }
        do { _ = try await production.list(token:nil); XCTFail("Invalid production endpoint") } catch {}
        XCTAssertEqual((try report()["events"] as? [[String:Any]])?.count,0)
    }
}

final class InventoryParserTests: XCTestCase {
    private func xml(_ content: String = "<Key>prefix%2Ffile.wav</Key><Size>4</Size><ETag>&quot;tag&quot;</ETag><LastModified>2026-01-01T00:00:00Z</LastModified>", extra: String = "", truncated: String = "false") -> String {
        "<ListBucketResult><Name>fixture</Name><Prefix>prefix%2F</Prefix><EncodingType>url</EncodingType><IsTruncated>\(truncated)</IsTruncated><Contents>\(content)</Contents>\(extra)</ListBucketResult>"
    }
    private func parse(_ value: String) throws -> InventoryPage { try InventoryXML.parse(Data(value.utf8),bucket:"fixture",prefix:"prefix") }
    func testParserRejectsMalformedUnscopedDuplicateAndInvalidInventory() throws {
        let good = xml()
        XCTAssertEqual(try parse(good).objects.first?.key,"prefix/file.wav")
        let invalid = [
            "<Error><Code>AccessDenied</Code></Error>", String(good.dropLast(5)),
            good.replacingOccurrences(of:"prefix%2Ffile.wav",with:"prefix-neighbor%2Ffile.wav"),
            good.replacingOccurrences(of:"<Size>4</Size>",with:"<Size>-1</Size>"),
            good.replacingOccurrences(of:"<Size>4</Size>",with:"<Size>9223372036854775808</Size>"),
            good.replacingOccurrences(of:"2026-01-01T00:00:00Z",with:"not-a-date"),
            good.replacingOccurrences(of:"<Size>4</Size>",with:"<Size>4</Size><Size>5</Size>"),
            good.replacingOccurrences(of:"prefix%2Ffile.wav",with:"bad%ZZ"),
            good.replacingOccurrences(of:"<EncodingType>url</EncodingType>",with:""),
            xml(truncated:"true"), xml(extra:"<NextContinuationToken>unexpected</NextContinuationToken>"),
            "<!DOCTYPE ListBucketResult [<!ENTITY x 'private'>]>" + good.replacingOccurrences(of:"file.wav",with:"&x;"),
            xml(extra:"<Name>different</Name>")
        ]
        for value in invalid { XCTAssertThrowsError(try parse(value),String(value.prefix(100))) }
    }
    func testSingleDecodeAndOpaqueContinuationToken() throws {
        let data = xml().replacingOccurrences(of:"prefix%2Ffile.wav",with:"prefix%2Fliteral%252F%2Ba.wav").replacingOccurrences(of:"<IsTruncated>false</IsTruncated>",with:"<IsTruncated>true</IsTruncated><NextContinuationToken>+/opaque%2F</NextContinuationToken>")
        let page = try parse(data)
        XCTAssertEqual(page.objects.first?.key,"prefix/literal%2F+a.wav"); XCTAssertEqual(page.nextToken,"+/opaque%2F")
    }
    func testEmptyAndThousandItemBounds() throws {
        let good = xml(), contents = good.components(separatedBy:"<Contents>")[1].components(separatedBy:"</Contents>")[0]
        let empty = good.replacingOccurrences(of:"<Contents>\(contents)</Contents>",with:"")
        XCTAssertEqual(try parse(empty).objects.count,0)
        func page(_ count: Int) -> String {
            empty.replacingOccurrences(of:"</ListBucketResult>",with:(0..<count).map { "<Contents>" + contents.replacingOccurrences(of:"file.wav",with:"file\($0).wav") + "</Contents>" }.joined() + "</ListBucketResult>")
        }
        XCTAssertEqual(try parse(page(1000)).objects.count,1000)
        XCTAssertThrowsError(try parse(page(1001)))
        XCTAssertThrowsError(try parse(String(repeating:"x",count:4_194_305)))
    }
}
