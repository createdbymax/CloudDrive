import XCTest
@testable import CloudDrive

final class UploadSpeedHistoryTests: XCTestCase {
    func testRetentionDropsOldSamplesAndRejectsInvalidRates() {
        var history = UploadSpeedHistory()
        let now = Date()
        history.record(bytesPerSecond: 5_000_000, pending: 10, at: now.addingTimeInterval(-4000))
        history.record(bytesPerSecond: .nan, pending: 9, at: now.addingTimeInterval(-10))
        history.record(bytesPerSecond: 2_000_000, pending: 8, at: now)
        XCTAssertEqual(history.samples.count, 2)
        XCTAssertNil(history.samples[0].bytesPerSecond)
    }
    func testStalledSecondsCountsOnlyAnsweredIdleIntervals() {
        var history = UploadSpeedHistory()
        let t = Date()
        history.record(bytesPerSecond: 0, pending: 5, at: t)
        history.record(bytesPerSecond: 40_000_000, pending: 5, at: t.addingTimeInterval(2))
        history.record(bytesPerSecond: nil, pending: 0, at: t.addingTimeInterval(4))
        history.record(bytesPerSecond: 0, pending: 5, at: t.addingTimeInterval(6))
        XCTAssertEqual(history.stalledSeconds(in: history.samples), 2, accuracy: 0.01)
        history.record(bytesPerSecond: 0, pending: 5, at: t.addingTimeInterval(8))
        XCTAssertEqual(history.stalledSeconds(in: history.samples), 4, accuracy: 0.01)
    }
}

final class NetworkOutSamplerTests: XCTestCase {
    func testFirstSampleIsNilThenFinite() {
        let sampler = NetworkOutSampler()
        let t = Date()
        XCTAssertNil(sampler.sample(now: t))
        let rate = sampler.sample(now: t.addingTimeInterval(1))
        XCTAssertNotNil(rate)
        XCTAssertGreaterThanOrEqual(rate ?? -1, 0)
    }
}
