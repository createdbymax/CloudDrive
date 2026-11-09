import XCTest
@testable import CloudDriveCore

private final class ChunkResponseProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    override func startLoading() {
        DispatchQueue.global().async { [self] in
            let path = request.url!.path
            if path == "/wait" { return }
            let size = path == "/large" ? 2 * 1024 * 1024 : 97
            let headers = path == "/chunked" ? [:] : ["Content-Length": String(path == "/head" ? 1_000_000_000 : size)]
            let response = HTTPURLResponse(url: request.url!, statusCode: path == "/conflict" ? 412 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" {
                for offset in stride(from: 0, to: size, by: 8192) {
                    lock.lock(); let stop = stopped; lock.unlock(); if stop { return }
                    client?.urlProtocol(self, didLoad: Data(repeating: 37, count: min(8192, size - offset)))
                }
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class BoundedHTTPResponseTests: XCTestCase {
    private func fixture() -> BoundedHTTPResponseClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChunkResponseProtocol.self]
        return BoundedHTTPResponseClient(configuration: config)
    }
    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var value = URLRequest(url: URL(string: "https://fixture.invalid" + path)!); value.httpMethod = method; return value
    }
    func testChunkedCollectionEnforcesCapAndHeadAllowsObjectLength() async throws {
        let client = fixture(); defer { client.close() }
        let (data, _) = try await client.data(for: request("/large"), maximum: 2 * 1024 * 1024) { _ in }
        XCTAssertEqual(data, Data(repeating: 37, count: 2 * 1024 * 1024))
        for path in ["/large", "/chunked"] {
            do { _ = try await client.data(for: request(path), maximum: 96) { _ in }; XCTFail("Oversize must fail") }
            catch { XCTAssertEqual(error as? StorageFailure, .invalidResponse) }
        }
        let (head, response) = try await client.data(for: request("/head", method: "HEAD"), maximum: 0) { _ in }
        XCTAssertTrue(head.isEmpty); XCTAssertEqual(response.expectedContentLength, 1_000_000_000)
    }
    func testStatusValidationAndCancellationArePromptAndIsolated() async throws {
        let client = fixture(); defer { client.close() }
        do {
            _ = try await client.data(for: request("/conflict"), maximum: 0) { response in
                if response.statusCode == 412 { throw StorageFailure.conflict }
            }
            XCTFail("Status failure must survive callback cancellation")
        } catch { XCTAssertEqual(error as? StorageFailure, .conflict) }
        let waiting = Task { try await client.data(for: self.request("/wait"), maximum: 100) { _ in } }
        try await Task.sleep(for: .milliseconds(20)); waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled request must throw") } catch { XCTAssertTrue(error is CancellationError) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let (data, _) = try await client.data(for: self.request("/chunked"), maximum: 97) { _ in }
                    XCTAssertEqual(data.count, 97)
                }
            }
            try await group.waitForAll()
        }
        let cancelledEarly = Task { try await client.data(for: self.request("/wait"), maximum: 100) { _ in } }
        cancelledEarly.cancel()
        do { _ = try await cancelledEarly.value; XCTFail("Early cancellation must throw") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCloseRacingTaskCreationSettlesEveryRequest() async {
        for _ in 0..<10 {
            let client = fixture()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        do { _ = try await client.data(for: self.request("/wait"), maximum: 100) { _ in }; XCTFail("Closed request must throw") }
                        catch { /* Cancellation before or after task creation is allowed. */ }
                    }
                }
                group.addTask { client.close() }
                await group.waitForAll()
            }
        }
    }
}
