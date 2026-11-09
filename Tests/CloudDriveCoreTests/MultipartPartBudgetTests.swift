import XCTest
@testable import CloudDriveCore

final class MultipartPartBudgetTests: XCTestCase {
    private func waitForQueue(_ budget: MultipartPartBudget, count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await budget.usage.waiting != count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        let waiting = await budget.usage.waiting
        XCTAssertEqual(waiting, count)
        return waiting == count
    }

    func testByteAllowanceIsSharedAcrossFilesAndCancelledWaiterDoesNotReserveIt() async throws {
        let budget = MultipartPartBudget(), part: Int64 = 64 * 1024 * 1024
        let first = try await budget.acquire(bytes: part), second = try await budget.acquire(bytes: part)
        let waiting = Task { try await budget.acquire(bytes: 1) }
        _ = await waitForQueue(budget, count: 1)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled admission succeeded") } catch is CancellationError {}
        let stillHeld = await budget.usage
        XCTAssertEqual(stillHeld.requests, 2); XCTAssertEqual(stillHeld.bytes, 128 * 1024 * 1024)
        XCTAssertEqual(stillHeld.waiting, 0)
        let nextFile = Task { try await budget.acquire(bytes: part) }
        _ = await waitForQueue(budget, count: 1)
        await budget.release(first)
        let third = try await nextFile.value, usage = await budget.usage
        XCTAssertEqual(usage.requests, 2); XCTAssertEqual(usage.bytes, 128 * 1024 * 1024)
        await budget.release(second); await budget.release(third)
    }

    func testRequestSlotsAreSharedAndRefilledOnRelease() async throws {
        let budget = MultipartPartBudget()
        var leases: [UUID] = []
        for _ in 0..<4 { leases.append(try await budget.acquire(bytes: 1)) }
        let fifth = Task { try await budget.acquire(bytes: 1) }
        _ = await waitForQueue(budget, count: 1)
        await budget.release(leases.removeFirst())
        leases.append(try await fifth.value)
        let usage = await budget.usage
        XCTAssertEqual(usage.requests, 4); XCTAssertEqual(usage.waiting, 0)
        for lease in leases { await budget.release(lease) }
    }

    func testFailedPartReleasesItsReservationBeforeReturning() async {
        let budget = MultipartPartBudget()
        do {
            let _: Int = try await budget.withLease(bytes: 64 * 1024 * 1024) { throw StorageFailure.offline }
            XCTFail("Part should fail")
        } catch { XCTAssertEqual(error as? StorageFailure, .offline) }
        let usage = await budget.usage
        XCTAssertEqual(usage.requests, 0); XCTAssertEqual(usage.bytes, 0)
    }
}
