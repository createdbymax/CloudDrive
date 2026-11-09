import XCTest
import SwiftUI
import AppKit
@testable import CloudDriveCore
@testable import CloudDrive

@MainActor final class NamespacePresentationTests: XCTestCase {
    private func status(pending: Int = 0, attention: Int = 0, local: Int64 = 4, published: Int64 = 4, dirty: Int64 = 0, phase: String = "idle") -> SyncEngineStatus {
        .init(phase: phase, pending: pending, attention: attention, localRevision: local, publishedRevision: published,
              dirtyBytes: dirty, cleanCacheBytes: 0, pinnedBytes: 0)
    }
    private func presentation(_ value: SyncEngineStatus?, running: Bool = true, mounted: Bool = true, error: String = "") -> NamespaceTransferPresentation {
        .init(enabled: true, running: running, mounted: mounted, readOnly: false, busy: false, status: value, error: error)
    }
    func testLocalSaveCannotBeShownAsCloudCompletionUntilPublicationCatchesUp() {
        let pending = presentation(status(pending: 1, local: 8, published: 7))
        XCTAssertEqual(pending.tone, .working)
        XCTAssertEqual(pending.title, "Saved on this Mac — syncing to R2")
        XCTAssertEqual(presentation(status(local: 8, published: 7)).tone, .working)
        XCTAssertEqual(presentation(status(dirty: 4096)).tone, .working)
        XCTAssertEqual(presentation(status()).tone, .published)
        XCTAssertEqual(presentation(status(), mounted: false).subtitle, "Finder is ejected. Cloud work is complete.")
    }
    func testUploadSpeedAppearsOnlyDuringFreshCloudSync() throws {
        var value = status(pending: 1, phase: "working")
        // Older engines omit the field.
        XCTAssertNil(try JSONDecoder().decode(SyncEngineStatus.self, from: JSONEncoder().encode(value)).uploadBytesPerSecond)
        XCTAssertNil(presentation(value).uploadSpeed)
        value.uploadBytesPerSecond = 2_500_000
        let expected = 2.5.formatted(.number.precision(.fractionLength(1))) + " MB/s"
        XCTAssertEqual(presentation(value).uploadSpeed, expected)
        XCTAssertEqual(presentation(value, mounted: false).uploadSpeed, expected)
        XCTAssertNil(presentation(value, running: false).uploadSpeed)
        XCTAssertNil(NamespaceTransferPresentation(enabled: true, running: true, mounted: true, readOnly: false, busy: false,
            status: value, error: "", statusIsFresh: false).uploadSpeed)
        value.phase = "paused"
        XCTAssertNil(presentation(value).uploadSpeed)
        value.phase = "working"
        value.uploadBytesPerSecond = 0
        XCTAssertEqual(presentation(value).uploadSpeed, UploadMetricText.speed(0))
        value.pending = 0
        XCTAssertNil(presentation(value).uploadSpeed)
    }
    func testEjectedWorkIsHealthyWhileUnknownFailedAndStoppedStatesAvoidSuccess() {
        let detached = presentation(status(pending: 2), mounted: false)
        XCTAssertEqual(detached.title, "Finder ejected — syncing changes")
        XCTAssertEqual(detached.tone, .working)
        XCTAssertEqual(presentation(nil).tone, .attention)
        XCTAssertEqual(presentation(status(attention: 1)).tone, .attention)
        XCTAssertEqual(presentation(status(), error: "Retry connection").tone, .attention)
        XCTAssertNotEqual(presentation(status(), running: false).tone, .published)
        XCTAssertNotEqual(presentation(status(phase: "unrecognized")).tone, .published)
        XCTAssertNotEqual(presentation(status(local: 4, published: 9)).tone, .published)
    }
    func testReadOnlyPreviewAndUnenabledOwnerDoNotClaimCloudPublication() {
        let preview = NamespaceTransferPresentation(enabled: false, running: true, mounted: true, readOnly: true, busy: false, status: status(), error: "")
        XCTAssertEqual(preview.title, "Read-only preview")
        XCTAssertNotEqual(preview.tone, .published)
        let unconfirmed = NamespaceTransferPresentation(enabled: false, running: true, mounted: true, readOnly: false, busy: false, status: status(), error: "")
        XCTAssertEqual(unconfirmed.tone, .attention)
    }
    func testCloudCopyLabelNeverConfirmsDirtyPausedInvalidOrStaleState() {
        for value in [status(dirty: 1), status(pending: 1), status(attention: 1), status(phase: "paused"), status(local: 2, published: 3)] {
            XCTAssertNotEqual(presentation(value).cloudCopyLabel, "Confirmed in R2")
        }
        let stale = NamespaceTransferPresentation(enabled: true, running: true, mounted: true, readOnly: false, busy: false,
            status: status(), error: "", statusIsFresh: false)
        XCTAssertEqual(stale.tone, .attention)
        XCTAssertNotEqual(stale.cloudCopyLabel, "Confirmed in R2")
        XCTAssertEqual(presentation(status()).cloudCopyLabel, "Confirmed in R2")
    }
    func testPinProgressAndMalformedCountersCannotClaimCompletion() {
        var value = status()
        value.requestedPins = 2; value.completedPins = 1
        XCTAssertEqual(presentation(value).title, "Downloading for offline use")
        value.pinAttention = 1
        XCTAssertEqual(presentation(value).tone, .attention)
        value.completedPins = 3
        XCTAssertFalse(NamespaceTransferPresentation.valid(value))
        value = status(); value.cleanCacheBytes = -1
        XCTAssertFalse(NamespaceTransferPresentation.valid(value))
    }
    func testActivityDistinguishesLocalCompletionAndStaleSamples() {
        let item = NamespaceActivityItem(id: UUID(), nodeID: UUID(), sequence: 1, name: "Fixture", path: "Fixture", kind: .rename,
            state: .complete, size: nil, attempts: 0, failureCode: nil, localOnly: true)
        XCTAssertEqual(NamespaceActivityPresentation.label(item, fresh: true), "Move or rename · Saved locally")
        XCTAssertEqual(NamespaceActivityPresentation.label(item, fresh: false), "Move or rename · Status unavailable")
    }
    func testFinderReadinessDoesNotConfuseIncludedComponentWithSuccessfulActivation() {
        let missing = FinderIntegrationPresentation(supportedSystem: true, componentPresent: false, mounted: false)
        XCTAssertEqual(missing.state, .componentMissing)
        let included = FinderIntegrationPresentation(supportedSystem: true, componentPresent: true, mounted: false)
        XCTAssertEqual(included.state, .activationUnconfirmed)
        XCTAssertTrue(included.detail.contains("does not prove"))
        XCTAssertEqual(FinderIntegrationPresentation(supportedSystem: true, componentPresent: true, mounted: true).state, .connected)
        XCTAssertEqual(FinderIntegrationPresentation(supportedSystem: false, componentPresent: true, mounted: false).state, .unsupportedSystem)
    }
    func testTrashDeletionConfirmationKeepsExactItemsAndConnectionBinding() {
        let node = NamespaceNode(id: UUID(), inode: 3, parentID: UUID(), name: "folder", kind: .directory)
        let entry = NamespaceTrashEntry(id: UUID(), node: node, originalParentID: UUID(), deletedAt: Date())
        let prompt = TrashDeletionConfirmation(entries: [entry], binding: "fixture-binding")
        XCTAssertEqual(prompt.entries.map(\.id), [entry.id])
        XCTAssertEqual(prompt.binding, "fixture-binding")
        XCTAssertEqual(prompt.title, "Delete this item permanently?")
    }
    func testFinderSelectionConfirmationNamesSingleFileAndCountsEverySelection() {
        XCTAssertEqual(FinderActionConfirmation.selectionLabel(paths: ["/drive/folder/song.wav"]), "“song.wav”")
        XCTAssertEqual(FinderActionConfirmation.selectionLabel(paths: ["/drive/a", "/drive/b"]), "2 items")
    }
    func testManagementAndTransferViewsRenderWithoutLaunchingOrCreatingANamespace() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-presentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let drive = Drive(root: directory, binary: directory.appendingPathComponent("unused"), helper: directory.appendingPathComponent("unused-helper"), useKeychain: false, autoRecover: false)
        let engine = drive.namespaceEngine
        let management = NSHostingView(rootView: NamespaceManagementView(drive: drive))
        management.frame = NSRect(x: 0, y: 0, width: 660, height: 520)
        management.layoutSubtreeIfNeeded()
        let transfers = NSHostingView(rootView: NamespaceTransfersView(engine: engine))
        transfers.frame = NSRect(x: 0, y: 0, width: 660, height: 520)
        transfers.layoutSubtreeIfNeeded()
        let trash = NSHostingView(rootView: NamespaceTrashView(drive: drive))
        trash.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        trash.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(trash.fittingSize.height, 0)
        let encryption = NSHostingView(rootView: DriveEncryptionSetupView(drive: drive))
        encryption.frame = NSRect(x: 0, y: 0, width: 660, height: 520)
        encryption.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(encryption.fittingSize.height, 0)
        let compact = NSHostingView(rootView: CompactDriveView(drive: drive, showSearch: {}))
        compact.frame = NSRect(x: 0, y: 0, width: 560, height: 240)
        compact.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(compact.fittingSize.height, 0)
        XCTAssertGreaterThan(management.fittingSize.height, 0)
        XCTAssertGreaterThan(transfers.fittingSize.height, 0)
        XCTAssertFalse(engine.running); XCTAssertFalse(engine.mounted); XCTAssertFalse(engine.hasSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("namespace-owner.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Namespaces").path))
    }
}
