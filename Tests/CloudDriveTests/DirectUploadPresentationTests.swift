import AppKit
import SwiftUI
import XCTest
@testable import CloudDrive

/// Isolated view rendering: synthetic metadata only; no credentials, source reads, provider or worker.
final class DirectUploadPresentationTests: XCTestCase {
    @MainActor func testPausedDashboardNamesDirectModeAndHidesFinderConnectionAction() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("direct-mode-dashboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = Connection(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "preview-bucket", prefix: "uploads", accessKey: "synthetic-access", secretKey: "synthetic-secret")
        let drive = Drive(root: root, binary: URL(fileURLWithPath: "/nonexistent-preview-backend"), helper: URL(fileURLWithPath: "/nonexistent-preview-helper"), useKeychain: false, autoRecover: false)
        drive.connection = connection
        try seed(records: drive.directUploads.recordsDirectory, connection: connection)
        await drive.recover()
        XCTAssertTrue(drive.canDirectUpload)
        XCTAssertFalse(drive.canConnect)
        XCTAssertEqual(drive.presentation.title, "Direct uploads paused")
        XCTAssertTrue(drive.presentation.subtitle.contains("Resume"))
        XCTAssertEqual(drive.directUploads.jobs.count, 3)
        for (scheme, appearance, name) in [(ColorScheme.light, NSAppearance.Name.aqua, "light"), (.dark, .darkAqua, "dark")] {
            let host = NSHostingView(rootView: ContentView(drive: drive).frame(width: 900, height: 700).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance); window.contentView = host
            host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10_000)
            if let output = ProcessInfo.processInfo.environment["CLOUDDRIVE_DIRECT_UPLOAD_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("direct-mode-dashboard-\(name).png"))
            }
            window.contentView = nil; window.close()
        }
    }

    @MainActor func testDirectUploadCardRendersRecoveredQueueInLightAndDark() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("direct-upload-presentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = root.appendingPathComponent("records")
        let connection = Connection(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "preview-bucket", prefix: "uploads", accessKey: "synthetic-access", secretKey: "synthetic-secret")
        try seed(records: records, connection: connection)
        let controller = DirectUploadController(defaultDirectory: records, rememberLocation: false)
        await controller.restoreIfNeeded()
        XCTAssertEqual(controller.jobs.count, 3)
        XCTAssertEqual(controller.jobs[0].status, .paused)
        XCTAssertEqual(controller.jobs[0].completedBytes, 64 * 1_048_576)
        XCTAssertEqual(controller.metrics.pending, 3)
        XCTAssertEqual(controller.completedBytes, 64 * 1_048_576)
        XCTAssertEqual(controller.metrics.foreignJobs(destination: connection.fingerprint), 0)
        let drive = Drive(root: root.appendingPathComponent("drive-state"), binary: URL(fileURLWithPath: "/nonexistent-preview-backend"), helper: URL(fileURLWithPath: "/nonexistent-preview-helper"), useKeychain: false, autoRecover: false)
        drive.connection = connection
        await drive.recover()
        XCTAssertTrue(drive.canDirectUpload)
        for (scheme, appearance, name) in [(ColorScheme.light, NSAppearance.Name.aqua, "light"), (.dark, .darkAqua, "dark")] {
            for expanded in [false, true] {
            let content = DirectUploadCard(drive: drive, uploads: controller, expanded: expanded)
                .padding(20).frame(width: 520).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: ceil(host.fittingSize.height)), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = window.contentLayoutRect
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10_000)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 520)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 250)
            if let output = ProcessInfo.processInfo.environment["CLOUDDRIVE_DIRECT_UPLOAD_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("direct-upload-\(expanded ? "details-" : "")\(name).png"))
            }
            window.contentView = nil
            window.close()
            }
        }
    }

    @MainActor func testRowDistinguishesFullPartsFromVerifiedCompletionAndGuardsActions() {
        let identity = UploadSourceIdentity(volume: "fixture", inode: 1, size: 64 * 1_048_576,
                                            modifiedSeconds: 1, modifiedNanos: 0, changedSeconds: 1, changedNanos: 0)
        var job = DirectUploadJob(batchID: UUID(), sourcePath: "/fixture/very-long-source-name.mov", source: identity,
                                  destination: String(repeating: "a", count: 64), key: "uploads/video.mov", partSize: 64 * 1_048_576)
        job.parts = [.init(number: 1, etag: String(repeating: "a", count: 32), md5: String(repeating: "a", count: 32), size: identity.size)]
        job.status = .checking; job.phase = .completing
        XCTAssertEqual(job.progress, 1)
        let checking = DirectUploadRowPresentation(job: job, active: true)
        XCTAssertFalse(checking.showsCompletion)
        XCTAssertEqual(checking.status, "Verifying")
        XCTAssertFalse(checking.canRetry(destination: job.destination, canDirectUpload: true, busy: true))
        XCTAssertFalse(checking.canCancel(destination: job.destination, canDirectUpload: true, busy: true))
        XCTAssertEqual(DirectUploadRowPresentation(job: job, active: false).status, "Verification pending")
        job.status = .attention
        let failed = DirectUploadRowPresentation(job: job, active: false)
        XCTAssertTrue(failed.canRetry(destination: job.destination, canDirectUpload: true, busy: false))
        XCTAssertFalse(failed.canRetry(destination: "other", canDirectUpload: true, busy: false))
        XCTAssertFalse(failed.canRetry(destination: job.destination, canDirectUpload: false, busy: false))
        job.phase = .queued; job.uploadID = nil
        XCTAssertTrue(DirectUploadRowPresentation(job: job, active: false).canCancel(destination: job.destination, canDirectUpload: false, busy: false))
        job.status = .uploaded
        XCTAssertTrue(DirectUploadRowPresentation(job: job, active: false).showsCompletion)
        XCTAssertFalse(DirectUploadRowPresentation(job: job, active: false).canCancel(destination: job.destination, canDirectUpload: true, busy: false))
    }

    @MainActor func testDropTargetSupportsKeyboardAndAccessibilityAndDisablesActivation() throws {
        _ = NSApplication.shared
        let target = UploadDropView()
        var activated = 0
        target.activate = { activated += 1 }
        XCTAssertTrue(target.accessibilityPerformPress())
        for keyCode: UInt16 in [36, 49, 76] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                                   isARepeat: false, keyCode: keyCode))
            target.keyDown(with: key)
        }
        XCTAssertEqual(activated, 4)
        target.enabled = false
        XCTAssertFalse(target.acceptsFirstResponder)
        XCTAssertFalse(target.accessibilityPerformPress())
        XCTAssertEqual(activated, 4)
    }

    @MainActor func testEmptyCardFitsNarrowDashboardInBothAppearances() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glass-upload-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = Drive(root: root, binary: URL(fileURLWithPath: "/nonexistent-preview-backend"), helper: URL(fileURLWithPath: "/nonexistent-preview-helper"), useKeychain: false, autoRecover: false)
        await drive.recover()
        for width in [440.0, 520.0] {
            for scheme in [ColorScheme.light, .dark] {
                let content = DirectUploadCard(drive: drive, uploads: drive.directUploads).padding(24).frame(width: width)
                    .fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                XCTAssertLessThan(host.fittingSize.height, 240, "Empty upload picker should stay compact")
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
            }
        }
    }

    @MainActor func testLargeQueueSummaryAvoidsHashingConnectionForEveryFile() {
        let connection = Connection(endpoint: "https://fixture.invalid", bucket: "preview", prefix: "uploads", accessKey: "synthetic", secretKey: "synthetic")
        let destination = connection.fingerprint
        let identity = UploadSourceIdentity(volume: "fixture", inode: 1, size: 100,
                                            modifiedSeconds: 1, modifiedNanos: 0, changedSeconds: 1, changedNanos: 0)
        let batch = UUID()
        var jobs = (0..<10_000).map { index in
            DirectUploadJob(batchID: batch, sourcePath: "/fixture/file-\(index).mov", source: identity,
                            destination: index.isMultiple(of: 10) ? String(repeating: "b", count: 64) : destination,
                            key: "uploads/file-\(index).mov", partSize: 64 * 1_048_576)
        }
        jobs[0].status = .paused; jobs[1].status = .attention; jobs[2].status = .checking
        jobs[3].status = .cancelled
        let legacyStart = Date()
        let legacyForeign = jobs.filter { !$0.terminal && $0.destination != connection.fingerprint }.count
        let legacySeconds = Date().timeIntervalSince(legacyStart)
        let start = Date()
        let metrics = DirectUploadQueueMetrics(jobs: jobs)
        let summarySeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(metrics.pending, 9_999)
        XCTAssertEqual(metrics.paused, 1)
        XCTAssertEqual(metrics.attention, 1)
        XCTAssertEqual(metrics.active, 1)
        XCTAssertEqual(metrics.totalBytes, 1_000_000)
        XCTAssertEqual(metrics.foreignJobs(destination: destination), legacyForeign)
        XCTAssertEqual(metrics.foreignJobs(destination: destination), 1_000)
        // Changing Waiting → Uploading must not reshuffle all the visible rows.
        let before = Array(metrics.orderedJobs.prefix(3).map(\.id))
        jobs[4].status = .uploading
        XCTAssertEqual(Array(DirectUploadQueueMetrics(jobs: jobs).orderedJobs.prefix(3).map(\.id)), before)
        XCTAssertLessThan(summarySeconds, legacySeconds)
        print("UPLOAD_CARD_10000_FILES legacy_foreign_ms=\(legacySeconds * 1000) complete_summary_ms=\(summarySeconds * 1000)")
    }

    @MainActor func testNativeFocusNotificationsOnlyPublishWhenFocusChanges() {
        let target = UploadDropView()
        var notifications: [Bool] = []
        target.focusChanged = { notifications.append($0) }
        XCTAssertTrue(target.becomeFirstResponder())
        XCTAssertTrue(target.becomeFirstResponder())
        XCTAssertTrue(target.resignFirstResponder())
        XCTAssertTrue(target.resignFirstResponder())
        XCTAssertEqual(notifications, [true, false])
    }

    @MainActor func testCompletedFileAdvancesItsOwnSlotWithoutMovingOtherRows() {
        let source = UploadSourceIdentity(volume: "fixture", inode: 1, size: 128,
                                          modifiedSeconds: 1, modifiedNanos: 0, changedSeconds: 1, changedNanos: 0)
        let batch = UUID()
        var jobs = (0..<5).map { i in
            DirectUploadJob(batchID: batch, sourcePath: "/fixture/file-\(i).mov", source: source,
                            destination: String(repeating: "a", count: 64), key: "uploads/file-\(i).mov", partSize: 64 * 1_048_576)
        }
        let initial = DirectUploadSlots.select(retaining: [], metrics: DirectUploadQueueMetrics(jobs: jobs))
        XCTAssertEqual(initial, Array(jobs.prefix(3).map(\.id)))
        jobs[0].status = .uploaded
        var slots = DirectUploadSlots.select(retaining: initial, metrics: DirectUploadQueueMetrics(jobs: jobs))
        XCTAssertEqual(slots, [jobs[3].id, jobs[1].id, jobs[2].id])
        jobs[1].status = .checking
        XCTAssertEqual(DirectUploadSlots.select(retaining: slots, metrics: DirectUploadQueueMetrics(jobs: jobs)), slots)
        jobs[3].status = .uploaded
        slots = DirectUploadSlots.select(retaining: slots, metrics: DirectUploadQueueMetrics(jobs: jobs))
        XCTAssertEqual(slots, [jobs[4].id, jobs[1].id, jobs[2].id])
        for i in jobs.indices { jobs[i].status = .uploaded }
        XCTAssertEqual(DirectUploadSlots.select(retaining: slots, metrics: DirectUploadQueueMetrics(jobs: jobs)), slots)
        XCTAssertEqual(Set(slots).count, slots.count)
    }

    @MainActor func testSidebarSwitchesViewsWithoutRecreatingTheUploadControllerOrQueue() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = Drive(root: root, binary: URL(fileURLWithPath: "/nonexistent-preview-backend"), helper: URL(fileURLWithPath: "/nonexistent-preview-helper"), useKeychain: false, autoRecover: false)
        drive.connection = Connection(endpoint: "https://fixture.invalid", bucket: "preview", prefix: "uploads", accessKey: "synthetic", secretKey: "synthetic")
        try seed(records: drive.directUploads.recordsDirectory, connection: drive.connection)
        await drive.recover()
        let controller = drive.directUploads
        let ids = controller.jobs.map(\.id)
        let confirmed = controller.completedBytes
        XCTAssertTrue(controller.hasSavedTransferRecords)
        let navigation = DashboardNavigation()
        let host = NSHostingView(rootView: ContentView(drive: drive, navigation: navigation).frame(width: 900, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        for _ in 0..<5 {
            navigation.showUploads()
            XCTAssertEqual(navigation.uploadSource, .finder)
            host.layoutSubtreeIfNeeded()
            navigation.destination = .drive
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(drive.directUploads === controller)
            XCTAssertEqual(controller.jobs.map(\.id), ids)
            XCTAssertEqual(controller.completedBytes, confirmed)
            XCTAssertTrue(controller.loaded)
        }
        navigation.showUploads(history: true)
        XCTAssertEqual(navigation.uploadSource, .direct)
        XCTAssertEqual(navigation.destination, .uploads)
        XCTAssertEqual(navigation.uploadFilter, .completed)
        navigation.showUploads(source: .finder)
        XCTAssertEqual(navigation.uploadSource, .finder)
        XCTAssertEqual(navigation.destination, .uploads)
        await controller.relinquishForTesting()
    }

    func testUploadWorkspaceFiltersKeepVerifiedHistorySeparateFromUnfinishedFiles() {
        let source = UploadSourceIdentity(volume: "fixture", inode: 1, size: 128,
                                          modifiedSeconds: 1, modifiedNanos: 0, changedSeconds: 1, changedNanos: 0)
        let statuses: [DirectUploadStatus] = [.waiting, .uploading, .paused, .checking, .attention, .cancelling, .uploaded, .cancelled]
        let jobs = statuses.enumerated().map { i, status in
            var job = DirectUploadJob(batchID: UUID(), sourcePath: "/fixture/file-\(i)", source: source,
                                      destination: String(repeating: "a", count: 64), key: "uploads/file-\(i)", partSize: 64 * 1_048_576)
            job.status = status
            return job
        }
        let metrics = DirectUploadQueueMetrics(jobs: jobs)
        XCTAssertEqual(DirectUploadFilter.queue.jobs(in: metrics).map(\.status), [.waiting, .uploading, .paused, .checking])
        XCTAssertEqual(DirectUploadFilter.attention.jobs(in: metrics).map(\.status), [.attention, .cancelling])
        XCTAssertEqual(DirectUploadFilter.completed.jobs(in: metrics).map(\.status), [.uploaded])
        XCTAssertEqual(metrics.orderedJobs.count, jobs.count, "Filtering must retain all original queue/history records")
    }

    private func seed(records: URL, connection: Connection) throws {
        let batch = UUID()
        let names = ["ceremony_cam-a.mov", "ceremony_cam-b.mov", "speeches.mov"]
        let sizes: [Int64] = [100 * 1_048_576, 400_000_000_000, 1_048_576]
        let jobs = zip(names.indices, names).map { index, name in
            let source = UploadSourceIdentity(volume: "synthetic-volume", inode: UInt64(index + 1), size: sizes[index], modifiedSeconds: 1, modifiedNanos: 0, changedSeconds: 1, changedNanos: 0)
            var job = DirectUploadJob(batchID: batch, sourcePath: "/Volumes/Preview Footage/\(name)", source: source, destination: connection.fingerprint, key: "uploads/\(name)", partSize: 64 * 1_048_576)
            job.status = index == 0 ? .uploading : .waiting
            if index == 0 {
                job.uploadID = "synthetic-session"
                job.parts = [.init(number: 1, etag: String(repeating: "a", count: 32), md5: String(repeating: "a", count: 32), size: 64 * 1_048_576)]
            }
            return job
        }
        let store = try UploadQueueStore(directory: records)
        try store.insert(jobs.map { job in var metadata = job; metadata.parts = []; return metadata })
        for job in jobs { for part in job.parts { try store.savePart(part, job: job) } }
    }
}
