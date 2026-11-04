import XCTest
@testable import CloudDrive

final class RuntimeTests: XCTestCase {
    static let valid = Data(#"{"fs":"bucket:fixture/drive","diskCache":{"path":"/private/cache/vfs/bucket/fixture/drive","uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0,"bytesUsed":10,"outOfSpace":false}}"#.utf8)
    func testStatsAreStrict() throws {
        XCTAssertTrue(try VFSStats.decode(Self.valid).diskCache.idle)
        for field in ["path", "uploadsQueued", "uploadsInProgress", "erroredFiles", "bytesUsed", "outOfSpace"] {
            var object = try JSONSerialization.jsonObject(with: Self.valid) as! [String:Any]
            var disk = object["diskCache"] as! [String:Any]; disk.removeValue(forKey: field); object["diskCache"] = disk
            XCTAssertThrowsError(try VFSStats.decode(JSONSerialization.data(withJSONObject: object)), field)
        }
        for replacement: Any in [-1, true, "0", NSNull()] {
            var object = try JSONSerialization.jsonObject(with: Self.valid) as! [String:Any]
            var disk = object["diskCache"] as! [String:Any]; disk["uploadsQueued"] = replacement; object["diskCache"] = disk
            XCTAssertThrowsError(try VFSStats.decode(JSONSerialization.data(withJSONObject: object)))
        }
    }
    func testCommandDeadlineKillsDescendantsAndReturnsPromptly() async throws {
        let start = Date()
        do {
            _ = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 30 & wait"], timeout: 0.2))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? RuntimeFailure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testCommandCancellationAndBoundedOutput() async throws {
        let task = Task { try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 30)) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error as? RuntimeFailure == .cancelled) }
        let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["sensitive-provider-output"], outputLimit: 4))
        XCTAssertEqual(result.output.count, 4); XCTAssertTrue(result.outputTruncated)
        XCTAssertFalse(result.diagnostic.contains("sensitive"))
    }
    func testEnvironmentIsNotInherited() async throws {
        setenv("CLOUDDRIVE_SECRET_TEST", "must-not-leak", 1)
        defer { unsetenv("CLOUDDRIVE_SECRET_TEST") }
        let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: []))
        XCTAssertFalse(String(decoding: result.output, as: UTF8.self).contains("must-not-leak"))
    }
    func testControlAbsoluteDeadlineAndMalformedPID() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ControlFixtureProtocol.self]
        let start = Date()
        do {
            _ = try await ControlClient(port: 12345, token: "hang", timeout: 0.15, configuration: config).stats()
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual(error as? RuntimeFailure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        for token in ["malformed", "badpid"] {
            let client = ControlClient(port: 12345, token: token, configuration: config)
            do { _ = try await client.pid(); XCTFail("Expected invalid PID") }
            catch { XCTAssertEqual(error as? RuntimeFailure, .invalidControlResponse) }
        }
        let pid = try await ControlClient(port: 12345, token: "test-only", configuration: config).pid()
        XCTAssertEqual(pid, 123)
    }
    func testControlAuthenticationAndInvalidResponses() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ControlFixtureProtocol.self]
        let client = ControlClient(port: 12345, token: "test-only", configuration: config)
        let stats = try await client.stats(); XCTAssertTrue(stats.diskCache.idle)
        let wrong = ControlClient(port: 12345, token: "wrong", configuration: config)
        do { _ = try await wrong.stats(); XCTFail("Expected unauthorized") }
        catch { XCTAssertEqual(error as? RuntimeFailure, .controlHTTP(401)) }
    }
}

private final class ControlFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        func token(_ value: String) -> Bool { auth == "Basic " + Data("bucketdrive:\(value)".utf8).base64EncodedString() }
        if token("hang") { return }
        let correct = token("test-only") || token("malformed") || token("badpid")
        let response = HTTPURLResponse(url: request.url!, statusCode: correct ? 200 : 401, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: Data
        if token("malformed") { body = Data("{}".utf8) }
        else if token("badpid") { body = Data("{\"pid\":true}".utf8) }
        else if request.url?.path == "/core/pid" { body = Data("{\"pid\":123}".utf8) }
        else { body = RuntimeTests.valid }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
