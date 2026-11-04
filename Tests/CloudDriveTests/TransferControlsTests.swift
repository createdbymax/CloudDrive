import XCTest
@testable import CloudDrive

final class TransferControlsTests: XCTestCase {
    func testDecimalLimitsAndExplicitRcloneUnits() {
        XCTAssertEqual(UploadLimit.unlimited.bytesPerSecond, -1)
        XCTAssertEqual(UploadLimit.unlimited.controlRate, "off")
        for limit in UploadLimit.allCases where limit != .unlimited {
            XCTAssertEqual(limit.bytesPerSecond, Int64(limit.rawValue) * 125_000)
            XCTAssertEqual(limit.controlRate, "\(limit.bytesPerSecond)B:off")
        }
        XCTAssertEqual(UploadLimit.mbps5.bytesPerSecond, 625_000)
    }
    func testStrictDirectionalReadbackAndUnsupportedLimits() throws {
        let good = try BandwidthStatus.decode(Data(#"{"bytesPerSecondTx":625000,"bytesPerSecondRx":-1,"rate":"irrelevant","bytesPerSecond":123}"#.utf8))
        XCTAssertEqual(good.uploadLimit, .mbps5)
        for json in [#"{}"#, #"{"bytesPerSecondTx":625000}"#, #"{"bytesPerSecondTx":true,"bytesPerSecondRx":-1}"#, #"{"bytesPerSecondTx":-2,"bytesPerSecondRx":-1}"#, #"{"bytesPerSecondTx":0,"bytesPerSecondRx":-1}"#, #"{"bytesPerSecondTx":625000,"bytesPerSecondRx":625000}"#, #"{"bytesPerSecondTx":"625000","bytesPerSecondRx":-1}"#] {
            XCTAssertThrowsError(try BandwidthStatus.decode(Data(json.utf8)), json)
        }
        XCTAssertNil(try BandwidthStatus.decode(Data(#"{"bytesPerSecondTx":123,"bytesPerSecondRx":-1}"#.utf8)).uploadLimit)
    }
    private func client(_ token: String) -> ControlClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TransferControlFixture.self]
        return ControlClient(port: 12345, token: token, configuration: config)
    }
    func testApplyAndSeparateReadbackMustBothMatch() async throws {
        let result = try await client("matching").setUploadLimit(.mbps5)
        XCTAssertEqual(result, .mbps5)
        for token in ["mutationMismatch", "readbackMismatch", "httpFailure", "malformed"] {
            do { _ = try await client(token).setUploadLimit(.mbps5); XCTFail("Expected failure for \(token)") }
            catch {}
        }
    }
    func testRetryRejectsActiveOrInvalidItemsAndMalformedSuccess() async throws {
        let active = UploadItem(id: 1, name: "fixture", size: 8, tries: 2, uploading: true)
        do { try await client("retry").requestUploadRetry(active, fs: "fixture:bucket"); XCTFail("Active retry should fail") } catch {}
        let queued = UploadItem(id: 1, name: "fixture", size: 8, tries: 2, uploading: false)
        try await client("retry").requestUploadRetry(queued, fs: "fixture:bucket")
        do { try await client("malformedRetry").requestUploadRetry(queued, fs: "fixture:bucket"); XCTFail("Malformed success should fail") } catch {}
        do { try await client("retry").requestUploadRetry(queued, fs: ""); XCTFail("Missing fs should fail") } catch {}
    }
}
private final class TransferControlFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var calls: [String:Int] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let encoded = String(auth.dropFirst("Basic ".count))
        let identity = Data(base64Encoded: encoded).flatMap { String(data:$0,encoding:.utf8) } ?? ""
        let token = String(identity.split(separator: ":").last ?? "")
        Self.lock.lock(); let count = (Self.calls[token] ?? 0) + 1; Self.calls[token] = count; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: token == "httpFailure" ? 500 : 200, httpVersion:nil, headerFields:nil)!
        client?.urlProtocol(self, didReceive:response, cacheStoragePolicy:.notAllowed)
        let body: String
        if request.url?.path == "/vfs/queue-set-expiry" { body = token == "malformedRetry" ? #"{"error":"bad"}"# : "{}" }
        else if token == "malformed" { body = "{}" }
        else if token == "mutationMismatch" || (token == "readbackMismatch" && count > 1) { body = #"{"bytesPerSecondTx":-1,"bytesPerSecondRx":-1}"# }
        else { body = #"{"bytesPerSecondTx":625000,"bytesPerSecondRx":-1}"# }
        client?.urlProtocol(self, didLoad:Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
