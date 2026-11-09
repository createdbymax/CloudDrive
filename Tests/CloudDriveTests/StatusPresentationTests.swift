import XCTest
@testable import CloudDrive

final class StatusPresentationTests: XCTestCase {
    private var empty: UploadProgressSnapshot {
        UploadProgressSnapshot(rows: [], totalBytes: 0, completedBytes: 0, speed: 0, eta: nil, progress: nil, queuedCount: 0, activeCount: 0, retryingCount: 0)
    }
    private func state(mount: MountState = .connected, uploads: UploadState = .idle,
                       busy: Bool = false, mounted: Bool = true, running: Bool = true,
                       auth: Bool = false, available: Bool = true, snapshot: UploadProgressSnapshot? = nil) -> StatusPresentation {
        StatusPresentation(mount: mount, uploads: uploads, busy: busy, mounted: mounted, running: running,
                           authorizationNeeded: auth, queueAvailable: available, snapshot: snapshot)
    }

    func testEmptyQueueCannotHideOwnershipOrCacheFailure() {
        XCTAssertEqual(state(mount: .blocked, snapshot: empty).title, "Finder browsing needs attention")
        XCTAssertEqual(state(mount: .unmounted, running: false, snapshot: empty).title, "Finder browsing needs attention")
        XCTAssertEqual(state(uploads: .outOfSpace, snapshot: empty).title, "Not enough local space")
        XCTAssertEqual(state(uploads: .failed(1), snapshot: empty).title, "Local cache needs attention")
    }
    func testIdleRequiresFreshRecognizableQueueAndHealthyMount() {
        XCTAssertEqual(state(snapshot: empty).title, "Drive connected")
        XCTAssertEqual(state(available: false, snapshot: empty).title, "Finder upload status unavailable")
        XCTAssertEqual(state(uploads: .unknown, snapshot: empty).title, "Finder upload status unavailable")
        XCTAssertEqual(state(uploads: .active(queued: 1, uploading: 0), snapshot: empty).title, "Finder upload status unavailable")
        XCTAssertEqual(state().title, "Finder upload status unavailable")
        XCTAssertEqual(state(mounted: false, snapshot: empty).title, "Drive disconnected")
    }
    func testAuthorizationAndOperationDoNotShowIdleSuccess() {
        XCTAssertEqual(state(auth: true, snapshot: empty).title, "Unlock your saved connection")
        XCTAssertEqual(state(busy: true, snapshot: empty).tone, .working)
        XCTAssertEqual(state(mount: .checking, snapshot: empty).title, "Checking Finder browsing…")
    }
    func testActiveRetryPresentationUsesOutstandingSnapshot() {
        let row = UploadProgressRow(id: 1, name: "fixture", size: 100, bytes: nil, speed: nil, eta: nil, progress: nil, label: "Retrying")
        let snapshot = UploadProgressSnapshot(rows: [row], totalBytes: 100, completedBytes: nil, speed: nil, eta: nil, progress: nil, queuedCount: 1, activeCount: 0, retryingCount: 1)
        XCTAssertEqual(state(uploads: .active(queued: 1, uploading: 0), snapshot: snapshot).title, "Finder uploads retrying")
    }
    func testEjectedBackgroundUploadsAndIdleAreNotMountFailures() {
        let row = UploadProgressRow(id: 1, name: "fixture", size: 100, bytes: nil, speed: nil, eta: nil, progress: nil, label: "Waiting")
        let pending = UploadProgressSnapshot(rows: [row], totalBytes: 100, completedBytes: nil, speed: nil, eta: nil, progress: nil, queuedCount: 1, activeCount: 0, retryingCount: 0)
        let working = state(mount: .unmounted, uploads: .active(queued: 1, uploading: 0), busy: true, mounted: false, snapshot: pending)
        XCTAssertEqual(working.title, "Finder ejected — finishing uploads")
        XCTAssertEqual(working.tone, .working)
        XCTAssertTrue(working.subtitle.contains("1 waiting"))
        let idle = state(mount: .unmounted, mounted: false, snapshot: empty)
        XCTAssertEqual(idle.title, "Finder ejected")
        XCTAssertEqual(idle.tone, .normal)
    }
    func testEjectedUnknownStatusAndErrorsStillNeedAttention() {
        for presentation in [
            state(mount: .unmounted, mounted: false, available: false, snapshot: empty),
            state(mount: .unmounted, uploads: .unknown, mounted: false, snapshot: empty),
            state(mount: .unmounted, mounted: false),
            state(mount: .unmounted, uploads: .active(queued: 1, uploading: 0), mounted: false, snapshot: empty)
        ] {
            XCTAssertEqual(presentation.title, "Finder ejected — background status unavailable")
            XCTAssertEqual(presentation.tone, .attention)
        }
        XCTAssertEqual(state(mount: .unmounted, uploads: .outOfSpace, mounted: false, snapshot: empty).title, "Not enough local space")
        XCTAssertEqual(state(mount: .unmounted, uploads: .failed(1), mounted: false, snapshot: empty).title, "Local cache needs attention")
        XCTAssertEqual(state(mount: .blocked, mounted: false, snapshot: empty).title, "Finder browsing needs attention")
        XCTAssertEqual(state(mount: .unmounted, mounted: false, auth: true, snapshot: empty).title, "Unlock your saved connection")
    }
    func testFiltersUseAuthoritativeQueueStateRatherThanDisplayText() {
        let uploading = UploadItem(id: 1, name: "a", size: 1, tries: 2, uploading: true)
        let queued = UploadItem(id: 2, name: "b", size: 1, tries: 0, uploading: false)
        XCTAssertTrue(TransferFilter.active.includes(uploading))
        XCTAssertTrue(TransferFilter.retrying.includes(uploading))
        XCTAssertFalse(TransferFilter.queued.includes(uploading))
        XCTAssertTrue(TransferFilter.queued.includes(queued))
        XCTAssertFalse(TransferFilter.retrying.includes(queued))
    }
    func testStaleOrFutureMetricsAreUnavailable() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(UploadFreshness.isFresh(now.addingTimeInterval(-5), at: now))
        XCTAssertFalse(UploadFreshness.isFresh(now.addingTimeInterval(-5.01), at: now))
        XCTAssertFalse(UploadFreshness.isFresh(now.addingTimeInterval(1), at: now))
        XCTAssertFalse(UploadFreshness.isFresh(nil, at: now))
        XCTAssertEqual(UploadMetricText.speed(.nan), "Speed unavailable")
        XCTAssertEqual(UploadMetricText.remaining(.infinity), "Time remaining unavailable")
    }
}
