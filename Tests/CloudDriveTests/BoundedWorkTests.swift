import XCTest
@testable import CloudDrive
final class BoundedWorkTests: XCTestCase {
    func testUncancellableOSWorkReturnsOnDeadline() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await BoundedWork<Int>.run(timeout: 0.05) { Thread.sleep(forTimeInterval: 0.4); return 7 }
            XCTFail("Expected a deadline")
        } catch { XCTAssertEqual(error as? RuntimeFailure, .timedOut) }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(300))
    }
    func testCancellationReturnsWithoutAcceptingLateResult() async throws {
        let task = Task { try await BoundedWork<Int>.run(timeout: 5) { Thread.sleep(forTimeInterval: 0.4); return 7 } }
        try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? RuntimeFailure, .cancelled) }
    }
}
