import XCTest
import Foundation
@testable import CloudDriveCore

private final class ManualUploadClock: UploadRateClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    func now() -> TimeInterval { lock.withLock { time } }
    var waiting: Int { lock.withLock { sleepers.count } }
    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    sleepers[id] = (time + seconds, continuation); return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }
    func advance(_ seconds: TimeInterval) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            time += seconds
            let ids = sleepers.filter { $0.value.0 <= time }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.1 }
        }
        for continuation in due { continuation.resume() }
    }
}

final class UploadBandwidthTests: XCTestCase {
    private func queued(_ count: Int, limiter: UploadBandwidthLimiter, clock: ManualUploadClock) async throws {
        for _ in 0..<10_000 {
            if await limiter.pendingRequests == count, count == 0 || clock.waiting > 0 { return }
            await Task.yield()
        }
        XCTFail("Limiter did not reach expected queued state"); throw StorageFailure.busy
    }
    func testConcurrentRequestsShareOneFIFOByteBudget() async throws {
        let clock = ManualUploadClock(), limiter = UploadBandwidthLimiter(initialBytesPerSecond: 100, clock: clock)
        let first = Task { try await limiter.acquire(bytes: 100) }; try await queued(1, limiter: limiter, clock: clock)
        let second = Task { try await limiter.acquire(bytes: 100) }; try await queued(2, limiter: limiter, clock: clock)
        let third = Task { try await limiter.acquire(bytes: 100) }; try await queued(3, limiter: limiter, clock: clock)
        clock.advance(1); try await queued(2, limiter: limiter, clock: clock); try await first.value
        clock.advance(1); try await queued(1, limiter: limiter, clock: clock); try await second.value
        clock.advance(1); try await queued(0, limiter: limiter, clock: clock); try await third.value
        XCTAssertEqual(clock.now(), 3)
    }
    func testCancellationDoesNotLeaveReservedBudgetBlockingTheNextUpload() async throws {
        let clock = ManualUploadClock(), limiter = UploadBandwidthLimiter(initialBytesPerSecond: 100, clock: clock)
        let first = Task { try await limiter.acquire(bytes: 1000) }; try await queued(1, limiter: limiter, clock: clock)
        let second = Task { try await limiter.acquire(bytes: 100) }; try await queued(2, limiter: limiter, clock: clock)
        first.cancel()
        do { try await first.value; XCTFail("cancelled upload must not be admitted") } catch is CancellationError {}
        try await queued(1, limiter: limiter, clock: clock)
        clock.advance(1); try await second.value
        let count = await limiter.pendingRequests; XCTAssertEqual(count, 0)
    }
    func testDynamicRateChangesAndUnlimitedWakePendingUploads() async throws {
        let clock = ManualUploadClock(), limiter = UploadBandwidthLimiter(initialBytesPerSecond: 1, clock: clock)
        let first = Task { try await limiter.acquire(bytes: 100) }; try await queued(1, limiter: limiter, clock: clock)
        try await limiter.setRate(bytesPerSecond: 100)
        // Wait for the replacement timer to be installed without advancing real time.
        for _ in 0..<100 { await Task.yield() }
        clock.advance(1); try await first.value
        let second = Task { try await limiter.acquire(bytes: 1000) }; try await queued(1, limiter: limiter, clock: clock)
        try await limiter.setRate(bytesPerSecond: 0); try await second.value
        let rate = await limiter.rateBytesPerSecond(); XCTAssertEqual(rate, 0)
        do { try await limiter.setRate(bytesPerSecond: -1); XCTFail() } catch StorageFailure.invalidRange {}
        do { try await limiter.acquire(bytes: UploadBandwidthLimiter.maximumAdmissionBytes + 1); XCTFail() } catch StorageFailure.invalidRange {}
    }
    func testReadsRemainUncappedAndMigrationQualificationSurvivesWrapping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bandwidth-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try FixtureStorageRemote(directory: directory.appendingPathComponent("remote"))
        let seeded = try await base.put(key: "Drive/file", data: Data("read now".utf8), condition: .absent, operationID: UUID())
        let clock = ManualUploadClock(), limiter = UploadBandwidthLimiter(initialBytesPerSecond: 1, clock: clock)
        let remote = BandwidthLimitedStorageRemote(base: base, limiter: limiter)
        let upload = Task { try await remote.put(key: "Drive/upload", data: Data("waiting".utf8), condition: .absent, operationID: UUID()) }
        try await queued(1, limiter: limiter, clock: clock)
        let read = try await remote.read(key: seeded.key, range: 0..<seeded.size, validator: seeded.validator)
        XCTAssertEqual(read.data, Data("read now".utf8)); XCTAssertEqual(clock.now(), 0)
        try await remote.qualifyConditionalDelete()
        upload.cancel(); do { _ = try await upload.value; XCTFail() } catch is CancellationError {}
        let absent = try await base.head(key: "Drive/upload"); XCTAssertNil(absent)
    }
    func testIdleBurstIsBoundedAndAlreadyCancelledRequestsNeverEnterQueue() async throws {
        let clock = ManualUploadClock(), limiter = UploadBandwidthLimiter(initialBytesPerSecond: 100, clock: clock)
        clock.advance(1_000_000)
        try await limiter.acquire(bytes: UploadBandwidthLimiter.maximumAdmissionBytes)
        let waiting = Task { try await limiter.acquire(bytes: 1) }; try await queued(1, limiter: limiter, clock: clock)
        waiting.cancel(); do { try await waiting.value; XCTFail() } catch is CancellationError {}
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; try await limiter.acquire(bytes: 1) }
        do { try await cancelled.value; XCTFail() } catch is CancellationError {}
        let count = await limiter.pendingRequests; XCTAssertEqual(count, 0)
    }
}
