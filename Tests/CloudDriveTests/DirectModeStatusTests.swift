import XCTest
@testable import CloudDrive

/// Pure presentation regressions: Finder mount state must not describe direct uploads as disconnected.
final class DirectModeStatusTests: XCTestCase {
    private var emptyFinderQueue: UploadProgressSnapshot {
        UploadProgressSnapshot(rows: [], totalBytes: 0, completedBytes: 0, speed: 0, eta: nil,
                               progress: nil, queuedCount: 0, activeCount: 0, retryingCount: 0)
    }

    private func state(_ direct: DirectUploadStatusSummary = .init(), mount: MountState = .disconnected,
                       uploads: UploadState = .unknown, mounted: Bool = false, running: Bool = false,
                       authorizationNeeded: Bool = false, busy: Bool = false,
                       queueAvailable: Bool = false) -> StatusPresentation {
        StatusPresentation(mount: mount, uploads: uploads, busy: busy, mounted: mounted,
                           running: running, authorizationNeeded: authorizationNeeded,
                           queueAvailable: queueAvailable, snapshot: queueAvailable ? emptyFinderQueue : nil,
                           direct: direct)
    }

    func testPausedDirectQueuePointsToResumeRatherThanConnectingFinder() {
        let status = state(.init(pending: 1705, paused: 1))
        XCTAssertEqual(status.title, "Direct uploads paused")
        XCTAssertTrue(status.subtitle.lowercased().contains("resume"))
        XCTAssertTrue(status.subtitle.lowercased().contains("finder"))
        XCTAssertFalse(status.title.lowercased().contains("disconnected"))
        XCTAssertFalse(status.subtitle.lowercased().contains("connect to"))
    }

    func testActiveDirectUploadDoesNotDependOnFinderQueueSamples() {
        let status = state(.init(pending: 10, active: true))
        XCTAssertEqual(status.title, "Uploading directly to R2")
        XCTAssertEqual(status.tone, .working)
        XCTAssertTrue(status.subtitle.lowercased().contains("finder"))
        XCTAssertFalse(status.title.lowercased().contains("unavailable"))
        XCTAssertFalse(status.title.lowercased().contains("disconnected"))
    }

    func testWaitingDirectQueueHasAnActionableDirectUploadStatus() {
        let status = state(.init(pending: 3))
        XCTAssertEqual(status.title, "Saved uploads are waiting")
        XCTAssertTrue(status.subtitle.lowercased().contains("resume"))
        XCTAssertFalse(status.title.lowercased().contains("disconnected"))
    }

    func testFinderConnectedWithSavedQueueOffersReview() {
        let status = state(.init(pending: 2137), mount: .connected, uploads: .idle,
                           mounted: true, running: true, queueAvailable: true)
        XCTAssertEqual(status.title, "Saved uploads are waiting")
        XCTAssertTrue(status.subtitle.lowercased().contains("finder"))
        XCTAssertTrue(status.subtitle.contains("Open Transfers"))
        XCTAssertFalse(status.title.lowercased().contains("no uploads"))
        XCTAssertFalse(status.subtitle.lowercased().contains("no uploads"))
    }

    func testRecordsAndDestinationErrorsRemainVisible() {
        let records = state(.init(pending: 5, paused: 1, recordsUnavailable: true))
        XCTAssertEqual(records.title, "Upload records unavailable")
        XCTAssertEqual(records.tone, .attention)
        XCTAssertTrue(records.subtitle.lowercased().contains("recover"))

        let destination = state(.init(pending: 5, paused: 1, foreign: 5))
        XCTAssertEqual(destination.title, "Uploads need their original connection")
        XCTAssertEqual(destination.tone, .attention)
    }

    func testFileErrorIsNotPresentedAsMerelyPaused() {
        let status = state(.init(pending: 8, paused: 1, attention: 2))
        XCTAssertEqual(status.title, "Direct uploads need attention")
        XCTAssertEqual(status.tone, .attention)
        XCTAssertTrue(status.subtitle.lowercased().contains("details"))
    }

    func testFinderBrowsingStatusIsExplicitWhenThereAreNoDirectUploads() {
        XCTAssertEqual(state().title, "Drive disconnected")
        let connected = state(mount: .connected, uploads: .idle, mounted: true, running: true,
                              queueAvailable: true)
        XCTAssertEqual(connected.title, "Drive connected")
        XCTAssertTrue(connected.subtitle.lowercased().contains("finder"))
    }

    func testDirectQueueCannotHideFinderOwnershipOrAuthorizationFailures() {
        let active = DirectUploadStatusSummary(pending: 1, active: true)
        for mount in [MountState.blocked, .unmounted] {
            let status = state(active, mount: mount)
            XCTAssertEqual(status.tone, .attention)
            XCTAssertNotEqual(status.title, "Uploading directly to R2")
        }
        let authorization = state(active, authorizationNeeded: true)
        XCTAssertEqual(authorization.title, "Unlock your saved connection")
        XCTAssertEqual(authorization.tone, .attention)
    }

    func testDirectQueueCannotHideLiveFinderCacheFailures() {
        let direct = DirectUploadStatusSummary(pending: 3)
        let space = state(direct, mount: .connected, uploads: .outOfSpace,
                          mounted: true, running: true, queueAvailable: true)
        XCTAssertEqual(space.title, "Not enough local space")
        XCTAssertEqual(space.tone, .attention)
        let failed = state(direct, mount: .connected, uploads: .failed(1),
                           mounted: true, running: true, queueAvailable: true)
        XCTAssertEqual(failed.tone, .attention)
        XCTAssertNotEqual(failed.title, "Saved uploads are waiting")
    }

    func testCheckingFinderOwnershipTakesPriorityOverDirectQueue() {
        let status = state(.init(pending: 3, active: true), mount: .checking)
        XCTAssertEqual(status.tone, .working)
        XCTAssertNotEqual(status.title, "Uploading directly to R2")
        XCTAssertTrue(status.title.lowercased().contains("checking"))
    }

    func testStaleOrUnknownLiveFinderQueueCannotBeHiddenByDirectWaitingFiles() {
        let direct = DirectUploadStatusSummary(pending: 3)
        let stale = state(direct, mount: .connected, uploads: .idle,
                          mounted: true, running: true, queueAvailable: false)
        XCTAssertEqual(stale.title, "Finder upload status unavailable")
        XCTAssertEqual(stale.tone, .attention)
        let unknown = state(direct, mount: .connected, uploads: .unknown,
                            mounted: true, running: true, queueAvailable: true)
        XCTAssertEqual(unknown.title, "Finder upload status unavailable")
        XCTAssertEqual(unknown.tone, .attention)
    }
}
