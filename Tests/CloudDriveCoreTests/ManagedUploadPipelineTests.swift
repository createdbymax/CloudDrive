import XCTest
@testable import CloudDriveCore

private actor UploadPreparationGate {
    private var started: Set<Int> = []
    private var finished: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observations: [(Set<Int>, XCTestExpectation)] = []
    private var allowed = true

    func prepare(_ index: Int) async -> Int {
        started.insert(index)
        let ready = observations.filter { $0.0.isSubset(of: started) }
        observations.removeAll { $0.0.isSubset(of: started) }
        for (_, expectation) in ready { expectation.fulfill() }
        if !finished.contains(index) {
            await withCheckedContinuation { waiters[index] = $0 }
        }
        return index
    }
    func expectStarts(_ indices: Set<Int>) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Preparation started: \(indices.sorted())")
        if indices.isSubset(of: started) { expectation.fulfill() }
        else { observations.append((indices, expectation)) }
        return expectation
    }
    func complete(_ index: Int) { finished.insert(index); waiters.removeValue(forKey: index)?.resume() }
    func snapshot() -> Set<Int> { started }
    func stop() { allowed = false }
    func canContinue() -> Bool { allowed }
}

final class ManagedUploadPipelineTests: XCTestCase {
    func testMixedClassesKeepLargeWorkAdmittedAndBoundBothLanes() {
        let mib: Int64 = 1024 * 1024
        var schedule = ManagedUploadSchedule(sizes: Array(repeating: 1 * mib, count: 20) + Array(repeating: 32 * mib, count: 20), maximumFiles: 8)
        var active: [Int: ManagedUploadSchedule.Admission] = [:]
        var admitted: [ManagedUploadSchedule.Lane] = []
        while let next = schedule.next() { active[next.index] = next; admitted.append(next.lane) }
        XCTAssertEqual(active.count, 8)
        XCTAssertEqual(Array(admitted.prefix(2)), [.small, .large])
        XCTAssertLessThanOrEqual(active.values.filter { $0.lane == .small }.count, 6)
        XCTAssertLessThanOrEqual(active.values.filter { $0.lane == .large }.count, 4)
        // Refill small completions while large jobs stay busy; large admission
        // retains four slots instead of being displaced by the small backlog.
        for _ in 0..<12 {
            let done = active.values.first { $0.lane == .small }!
            active.removeValue(forKey: done.index); schedule.complete(done)
            while let next = schedule.next() { active[next.index] = next }
            XCTAssertEqual(active.values.filter { $0.lane == .large }.count, 4)
            XCTAssertLessThanOrEqual(active.count, 8)
        }
    }

    func testSingleClassBorrowsSpareSlotsWithinSharedReaderAllowance() {
        var small = ManagedUploadSchedule(sizes: Array(repeating: 4096, count: 12), maximumFiles: 8)
        var admissions: [ManagedUploadSchedule.Admission] = []
        while let next = small.next() { admissions.append(next) }
        XCTAssertEqual(admissions.count, 8)
        var large = ManagedUploadSchedule(sizes: Array(repeating: 32 * 1024 * 1024, count: 12), maximumFiles: 8)
        admissions = []
        while let next = large.next() { admissions.append(next) }
        XCTAssertEqual(admissions.count, 8)
        // Very large files use the native maximum 64 MiB reader, so the shared
        // 256 MiB allowance admits four, even with eight available file slots.
        var huge = ManagedUploadSchedule(sizes: Array(repeating: 624 * 1024 * 1024 * 1024, count: 12), maximumFiles: 8)
        admissions = []
        while let next = huge.next() { admissions.append(next) }
        XCTAssertEqual(admissions.count, 4)
        XCTAssertEqual(admissions.reduce(Int64(0)) { $0 + $1.readerBytes }, 256 * 1024 * 1024)
    }

    func testRollingRefillDoesNotWaitForSlowSibling() async {
        let gate = UploadPreparationGate()
        let job = Task {
            await ManagedUploadPipeline.run(sizes: [1, 1, 1, 1], maximumFiles: 2,
                shouldContinue: { await gate.canContinue() }, prepare: { await gate.prepare($0) })
        }
        await fulfillment(of: [gate.expectStarts([0, 1])], timeout: 2)
        await gate.complete(1)
        await fulfillment(of: [gate.expectStarts([2])], timeout: 2)
        let whileFirstBlocked = await gate.snapshot()
        XCTAssertEqual(whileFirstBlocked, [0, 1, 2])
        await gate.complete(2)
        await fulfillment(of: [gate.expectStarts([3])], timeout: 2)
        await gate.complete(3); await gate.complete(0)
        let results = await job.value
        XCTAssertEqual(results.count, 4)
        for index in 0..<4 { XCTAssertEqual(try? results[index]?.get(), index) }
    }

    func testPauseStopsRefillButLetsAdmittedPayloadsSettle() async {
        let gate = UploadPreparationGate()
        let job = Task {
            await ManagedUploadPipeline.run(sizes: [1, 1, 1], maximumFiles: 2,
                shouldContinue: { await gate.canContinue() }, prepare: { await gate.prepare($0) })
        }
        await fulfillment(of: [gate.expectStarts([0, 1])], timeout: 2)
        await gate.stop()
        await gate.complete(1); await gate.complete(0)
        let results = await job.value, started = await gate.snapshot()
        XCTAssertEqual(started, [0, 1]); XCTAssertEqual(results.count, 2)
    }

    func testFailureStopsRefillWithoutDiscardingAdmittedResults() async {
        let gate = UploadPreparationGate()
        let job = Task {
            await ManagedUploadPipeline.run(sizes: [1, 1, 1], maximumFiles: 2,
                shouldContinue: { await gate.canContinue() }, prepare: { index in
                    _ = await gate.prepare(index)
                    if index == 0 { throw StorageFailure.offline }
                    return index
                })
        }
        await fulfillment(of: [gate.expectStarts([0, 1])], timeout: 2)
        let noRefill = await gate.expectStarts([2]); noRefill.isInverted = true
        await gate.complete(0)
        await fulfillment(of: [noRefill], timeout: 0.1)
        await gate.complete(1)
        let results = await job.value, started = await gate.snapshot()
        XCTAssertEqual(started, [0, 1]); XCTAssertEqual(results.count, 2)
        guard case .failure(let error) = results[0] else { return XCTFail("Expected failed payload result") }
        XCTAssertEqual(error as? StorageFailure, .offline)
        XCTAssertEqual(try? results[1]?.get(), 1)
    }
}
