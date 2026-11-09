import XCTest
@testable import CloudDrive

final class UploadSchedulingTests: XCTestCase {
    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { XCTFail("The scheduling state did not become observable"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testMemoryBudgetRejectsInvalidOrOversizedRequestsWithoutAllocating() async throws {
        let budget = UploadMemoryBudget(limit: 10)
        for bytes: Int64 in [0, -1, 11, Int64.max] {
            do { _ = try await budget.acquire(bytes: bytes); XCTFail("Invalid request must fail") }
            catch { XCTAssertEqual(error as? UploadSchedulingError, .invalidMemoryRequest) }
        }
        let state = await budget.snapshot()
        XCTAssertEqual(state.used, 0); XCTAssertEqual(state.permits, 0); XCTAssertEqual(state.waiting, 0)
    }

    func testMemoryAdmissionIsFIFOAndNeverExceedsGlobalLimit() async throws {
        let budget = UploadMemoryBudget(limit: 10)
        let held = try await budget.acquire(bytes: 8)
        let first = Task { try await budget.acquire(bytes: 8) }
        try await eventually { await budget.snapshot().waiting == 1 }
        let second = Task { try await budget.acquire(bytes: 2) }
        try await eventually { await budget.snapshot().waiting == 2 }
        let blocked = await budget.snapshot()
        XCTAssertEqual(blocked.used, 8, "The smaller request must not bypass the earlier blocked request")
        await budget.release(token: held)
        let a = try await first.value, b = try await second.value
        let full = await budget.snapshot()
        XCTAssertEqual(full.used, 10); XCTAssertEqual(full.peak, 10); XCTAssertEqual(full.permits, 2)
        await budget.release(token: a); await budget.release(token: b)
        let empty = await budget.snapshot()
        XCTAssertEqual(empty.used, 0); XCTAssertEqual(empty.permits, 0)
    }

    func testCancellingMemoryHeadUnblocksLaterRequestThatFits() async throws {
        let budget = UploadMemoryBudget(limit: 10)
        let held = try await budget.acquire(bytes: 8)
        let first = Task { try await budget.acquire(bytes: 8) }
        try await eventually { await budget.snapshot().waiting == 1 }
        let second = Task { try await budget.acquire(bytes: 2) }
        try await eventually { await budget.snapshot().waiting == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled acquisition must fail") } catch is CancellationError { }
        let granted = try await second.value
        let state = await budget.snapshot()
        XCTAssertEqual(state.used, 10); XCTAssertEqual(state.waiting, 0)
        await budget.release(token: held); await budget.release(token: granted)
        let final = await budget.snapshot(); XCTAssertEqual(final.used, 0)
    }

    func testMemoryGrantCancellationRaceDoesNotLeakPermits() async throws {
        let budget = UploadMemoryBudget(limit: 64)
        for iteration in 0..<50 {
            let held = try await budget.acquire(bytes: 64)
            let task = Task {
                let token = try await budget.acquire(bytes: 64)
                await budget.release(token: token)
            }
            try await eventually { await budget.snapshot().waiting == 1 }
            if iteration.isMultiple(of: 2) {
                let release = Task { await budget.release(token: held) }
                task.cancel()
                await release.value
            } else {
                await budget.release(token: held)
                task.cancel()
            }
            _ = try? await task.value
            let state = await budget.snapshot()
            XCTAssertEqual(state.used, 0); XCTAssertEqual(state.permits, 0); XCTAssertEqual(state.waiting, 0)
        }
    }

    func testMemoryWaitingMetadataIsBoundedAndCancelledWaitersRetire() async throws {
        let budget = UploadMemoryBudget(limit: 1, maximumWaiters: 2)
        let held = try await budget.acquire(bytes: 1)
        let first = Task { try await budget.acquire(bytes: 1) }
        try await eventually { await budget.snapshot().waiting == 1 }
        let second = Task { try await budget.acquire(bytes: 1) }
        try await eventually { await budget.snapshot().waiting == 2 }
        do { _ = try await budget.acquire(bytes: 1); XCTFail("Waiting queue must be bounded") }
        catch { XCTAssertEqual(error as? UploadSchedulingError, .queueFull) }
        first.cancel(); second.cancel()
        _ = try? await first.value; _ = try? await second.value
        await budget.release(token: held)
        let state = await budget.snapshot(); XCTAssertEqual(state.waiting, 0); XCTAssertEqual(state.used, 0)
    }

    func testDuplicateReleaseCannotIncreaseCapacityAndLargeArithmeticDoesNotOverflow() async throws {
        let budget = UploadMemoryBudget(limit: Int64.max)
        let token = try await budget.acquire(bytes: Int64.max)
        await budget.release(token: token); await budget.release(token: token); await budget.release(token: UUID())
        let state = await budget.snapshot()
        XCTAssertEqual(state.used, 0); XCTAssertEqual(state.peak, Int64.max); XCTAssertEqual(state.permits, 0)
    }

    func testRateLimiterDoesNotAllowInitialPayloadBurst() async throws {
        let limiter = UploadRateLimiter(bytesPerSecond: 1_000)
        let start = ContinuousClock.now
        try await limiter.waitToSend(bytes: 100)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(85))
        let state = await limiter.snapshot(); XCTAssertEqual(state.grantedBytes, 100); XCTAssertEqual(state.waiting, 0)
    }

    func testSharedRateLimitAggregatesConcurrentReservations() async throws {
        let limiter = UploadRateLimiter(bytesPerSecond: 1_000)
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try await limiter.waitToSend(bytes: 25) } }
            try await group.waitForAll()
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(85), "The aggregate limit must not multiply by the number of concurrent files")
        let state = await limiter.snapshot(); XCTAssertEqual(state.grantedBytes, 100); XCTAssertEqual(state.waiting, 0)
    }

    func testCancellingRateHeadDoesNotLeaveAStaleReservation() async throws {
        let limiter = UploadRateLimiter(bytesPerSecond: 1_000)
        let first = Task { try await limiter.waitToSend(bytes: 1_000) }
        try await eventually { await limiter.snapshot().waiting == 1 }
        let second = Task { try await limiter.waitToSend(bytes: 10) }
        try await eventually { await limiter.snapshot().waiting == 2 }
        let cancelledAt = ContinuousClock.now
        first.cancel()
        do { try await first.value; XCTFail("Cancelled reservation must fail") } catch is CancellationError { }
        try await second.value
        XCTAssertLessThan(cancelledAt.duration(to: .now), .milliseconds(600))
        let state = await limiter.snapshot(); XCTAssertEqual(state.grantedBytes, 10); XCTAssertEqual(state.waiting, 0)
    }

    func testCancellingNonHeadRateRequestPreservesFIFOWithoutWastingItsCapacity() async throws {
        let limiter = UploadRateLimiter(bytesPerSecond: 1_000)
        let first = Task { try await limiter.waitToSend(bytes: 40) }
        try await eventually { await limiter.snapshot().waiting == 1 }
        let middle = Task { try await limiter.waitToSend(bytes: 1_000) }
        try await eventually { await limiter.snapshot().waiting == 2 }
        let last = Task { try await limiter.waitToSend(bytes: 10) }
        try await eventually { await limiter.snapshot().waiting == 3 }
        middle.cancel()
        do { try await middle.value; XCTFail("Cancelled middle reservation must fail") } catch is CancellationError { }
        let start = ContinuousClock.now
        try await first.value; try await last.value
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(600))
        let state = await limiter.snapshot(); XCTAssertEqual(state.grantedBytes, 50); XCTAssertEqual(state.waiting, 0)
    }

    func testUnlimitedRateReturnsWithoutQueueingAndValidatesRequests() async throws {
        let limiter = UploadRateLimiter(bytesPerSecond: -1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { try await limiter.waitToSend(bytes: 1_024) } }
            try await group.waitForAll()
        }
        try await limiter.waitToSend(bytes: 0)
        let state = await limiter.snapshot(); XCTAssertEqual(state.grantedBytes, 16 * 1_024); XCTAssertEqual(state.waiting, 0)
        for bytes: Int64 in [-1, Int64.max] {
            do { try await limiter.waitToSend(bytes: bytes); XCTFail("Invalid rate request must fail") }
            catch { XCTAssertEqual(error as? UploadSchedulingError, .invalidRateRequest) }
        }
    }

    func testRateWaitingMetadataIsBounded() async throws {
        let limiter = UploadRateLimiter(bytesPerSecond: 1_000, maximumWaiters: 2)
        let first = Task { try await limiter.waitToSend(bytes: 1_000) }
        try await eventually { await limiter.snapshot().waiting == 1 }
        let second = Task { try await limiter.waitToSend(bytes: 1_000) }
        try await eventually { await limiter.snapshot().waiting == 2 }
        do { try await limiter.waitToSend(bytes: 1); XCTFail("The rate queue must be bounded") }
        catch { XCTAssertEqual(error as? UploadSchedulingError, .queueFull) }
        first.cancel(); second.cancel()
        _ = try? await first.value; _ = try? await second.value
        let state = await limiter.snapshot(); XCTAssertEqual(state.waiting, 0); XCTAssertEqual(state.grantedBytes, 0)
    }

    func testAlreadyCancelledTasksCannotAcquireBudgetOrRateReservation() async throws {
        let budget = UploadMemoryBudget(limit: 10), limiter = UploadRateLimiter(bytesPerSecond: 1_000)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await budget.acquire(bytes: 10); XCTFail("Cancelled memory acquisition must fail") }
            catch { XCTAssertTrue(error is CancellationError) }
            do { try await limiter.waitToSend(bytes: 10); XCTFail("Cancelled rate reservation must fail") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        let memory = await budget.snapshot(), rate = await limiter.snapshot()
        XCTAssertEqual(memory.used, 0); XCTAssertEqual(rate.waiting, 0); XCTAssertEqual(rate.grantedBytes, 0)
    }
}
