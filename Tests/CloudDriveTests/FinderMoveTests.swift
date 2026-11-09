import XCTest
@testable import CloudDrive

final class FinderMoveTests: XCTestCase {
    private func response(_ changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["version": 1, "enabled": true, "active": false, "needsRecovery": false, "phase": "idle", "completed": 0, "total": 0, "message": ""]
        value.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testUnknownAndContradictoryMoveStatesAreRejected() throws {
        for value: [String: Any] in [["version": 2], ["phase": "mystery"], ["completed": 2, "total": 1], ["active": true, "needsRecovery": true], ["active": true], ["enabled": false, "needsRecovery": true]] {
            XCTAssertThrowsError(try FinderMoveStatus.decode(response(value)))
        }
        XCTAssertThrowsError(try FinderMoveStatus.decode(Data("{}".utf8)))
        let state = try FinderMoveStatus.decode(response(["phase": "copying", "active": true, "total": 2]))
        XCTAssertFalse(state.safeToStop)
        XCTAssertEqual(state.title, "Moving 0 of 2 files")
        let preparing = try FinderMoveStatus.decode(response(["phase": "preparing", "active": true, "completed": 20, "total": 100]))
        XCTAssertEqual(preparing.title, "Preparing move: 20 of 100 items checked")
    }
    func testMovesOverrideAnEmptyUploadQueueAndBlockSafeStop() throws {
        let move = try FinderMoveStatus.decode(response(["phase": "needsRecovery", "needsRecovery": true]))
        XCTAssertFalse(move.safeToStop)
        let status = StatusPresentation(mount: .connected, uploads: .idle, busy: false, mounted: true, running: true, authorizationNeeded: false, queueAvailable: true, snapshot: UploadProgressSnapshot(rows: [], totalBytes: 0, completedBytes: 0, speed: 0, eta: nil, progress: nil, queuedCount: 0, activeCount: 0, retryingCount: 0), moves: move)
        XCTAssertEqual(status.title, "Move needs attention")
        XCTAssertEqual(status.tone, .attention)
        let unknown = StatusPresentation(mount: .connected, uploads: .idle, busy: false, mounted: true, running: true, authorizationNeeded: false, queueAvailable: true, snapshot: UploadProgressSnapshot(rows: [], totalBytes: 0, completedBytes: 0, speed: 0, eta: nil, progress: nil, queuedCount: 0, activeCount: 0, retryingCount: 0), moveStatusUnknown: true)
        XCTAssertEqual(unknown.title, "Move status unavailable")
    }
    func testEjectedMoveShowsProgressWhileBackgroundWorkFinishes() throws {
        let move = try FinderMoveStatus.decode(response(["phase": "copying", "active": true, "completed": 3, "total": 8]))
        let status = StatusPresentation(mount: .unmounted, uploads: .idle, busy: true, mounted: false, running: true, authorizationNeeded: false, queueAvailable: true, snapshot: nil, moves: move)
        XCTAssertEqual(status.title, "Finder ejected — finishing move")
        XCTAssertTrue(status.subtitle.contains("Moving 3 of 8 files"))
        XCTAssertEqual(status.tone, .working)
        let blocked = StatusPresentation(mount: .blocked, uploads: .idle, busy: false, mounted: false, running: true, authorizationNeeded: false, queueAvailable: true, snapshot: nil, moves: move)
        XCTAssertEqual(blocked.title, "Finder browsing needs attention")
    }
    func testEjectedMoveRecoveryAndUnknownStatusRemainAttention() throws {
        for phase in ["needsRecovery", "failed"] {
            let move = try FinderMoveStatus.decode(response(["phase": phase, "needsRecovery": phase == "needsRecovery"]))
            let status = StatusPresentation(mount: .unmounted, uploads: .idle, busy: true, mounted: false, running: true, authorizationNeeded: false, queueAvailable: true, snapshot: nil, moves: move)
            XCTAssertEqual(status.title, move.title)
            XCTAssertEqual(status.tone, .attention)
        }
        let unknown = StatusPresentation(mount: .unmounted, uploads: .idle, busy: true, mounted: false, running: true, authorizationNeeded: false, queueAvailable: true, snapshot: nil, moveStatusUnknown: true)
        XCTAssertEqual(unknown.title, "Finder ejected — background status unavailable")
        XCTAssertEqual(unknown.tone, .attention)
    }
    func testRecordedRouteChecksPrivacyBindingCompletionAndRelativeNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("move.json", isDirectory: false)
        func write(_ changes: [String: Any] = [:]) throws {
            var fields: [String: Any] = ["version": 1, "id": String(repeating: "a", count: 32), "binding": "fixture", "complete": false,
                                          "source": "Music/Track 1", "destination": "Archive/Track 1"]
            fields.merge(changes) { _, new in new }
            try JSONSerialization.data(withJSONObject: fields).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func route() -> FinderMoveRecords.Route? { FinderMoveRecords.recordedRoute(in: root, expectedBinding: "fixture") }
        try write()
        XCTAssertEqual(route(), .init(source: "Music/Track 1", destination: "Archive/Track 1"))
        for invalid: [String: Any] in [["binding": "foreign"], ["complete": true], ["source": "../escape"], ["source": "/absolute"], ["destination": "false\nstatus"], ["id": "invalid"]] {
            try write(invalid); XCTAssertNil(route())
        }
        try write()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertNil(route())
        let alternate = root.appendingPathComponent("alternate", isDirectory: false)
        try FileManager.default.moveItem(at: file, to: alternate)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: alternate)
        XCTAssertNil(route())
    }
    func testGenericRenameFailureOffersCollisionCheckAndPreservesSpecificWorkerMessages() throws {
        let generic = try FinderMoveStatus.decode(response(["phase": "failed", "message": "Move could not finish. Check storage access and try again."]))
        XCTAssertTrue(generic.displayMessage.contains("If it already contains a folder"))
        XCTAssertTrue(generic.displayMessage.contains("choose a different name"))
        for mount: MountState in [.connected, .unmounted] {
            let status = StatusPresentation(mount: mount, uploads: .idle, busy: false, mounted: mount == .connected,
                running: true, authorizationNeeded: false, queueAvailable: true, snapshot: nil, moves: generic)
            XCTAssertEqual(status.subtitle, generic.displayMessage)
        }
        for (phase, recovery, message) in [("failed", false, "Close open files or wait for uploads to finish."),
            ("needsRecovery", true, "An interrupted move needs to finish. Choose Resume move.")] {
            let status = try FinderMoveStatus.decode(response(["phase": phase, "needsRecovery": recovery, "message": message]))
            XCTAssertEqual(status.displayMessage, message)
        }
    }
    func testConcurrentStatusCannotHideActiveOrInterruptedJobsAndResumeIsScoped() throws {
        func job(_ id: String, active: Bool) -> [String: Any] {
            ["id": id, "source": "From" + id, "destination": "To" + id, "active": active, "needsRecovery": !active,
             "phase": active ? "copying" : "needsRecovery", "completed": 2, "total": 8, "message": ""]
        }
        let moving = job("first", active: true), interrupted = job("second", active: false)
        let fields: [String: Any] = ["active": true, "needsRecovery": true, "phase": "copying", "jobs": [moving, interrupted]]
        let mixed = try FinderMoveStatus.decode(response(fields))
        XCTAssertTrue(mixed.holdsWorker); XCTAssertFalse(mixed.safeToStop)
        XCTAssertEqual(mixed.recoverableJobs.map(\.id), ["second"])
        XCTAssertNil(mixed.resumeBody(id: nil)); XCTAssertNil(mixed.resumeBody(id: "stale")); XCTAssertNil(mixed.resumeBody(id: "first"))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(mixed.resumeBody(id: "second"))) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, "second"); XCTAssertEqual(body["resume"] as? Bool, true)
        for update: [String: Any] in [["active": false], ["needsRecovery": false], ["jobs": [moving, moving]], ["jobs": [moving, interrupted, moving, interrupted, moving]]] {
            XCTAssertThrowsError(try FinderMoveStatus.decode(response(fields.merging(update) { _, new in new })))
        }
        var invalid = interrupted; invalid["id"] = "invalid-2"; invalid["source"] = ""; invalid["destination"] = ""
        let retained = try FinderMoveStatus.decode(response(["needsRecovery": true, "phase": "needsRecovery", "jobs": [invalid]]))
        XCTAssertFalse(retained.safeToStop); XCTAssertNil(retained.resumeBody(id: "invalid-2"))
        XCTAssertTrue(try FinderMoveStatus.decode(response(["jobs": []])).safeToStop)
        let legacy = try FinderMoveStatus.decode(response(["needsRecovery": true, "phase": "needsRecovery"]))
        XCTAssertNotNil(legacy.resumeBody(id: nil)); XCTAssertNil(legacy.resumeBody(id: "second"))
    }
    func testSecondaryMoveJournalsHoldWriterAfterColdStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("move.json", isDirectory: false)
        let third = root.appendingPathComponent("move-3.json", isDirectory: false)
        func record(_ complete: Bool) throws -> Data { try JSONSerialization.data(withJSONObject: ["version": 1, "binding": "fixture", "complete": complete]) }
        try record(true).write(to: old); try record(false).write(to: third)
        XCTAssertTrue(try FinderMoveRecords.pending(in: root, expectedBinding: "fixture"))
        try record(true).write(to: third); XCTAssertFalse(try FinderMoveRecords.pending(in: root, expectedBinding: "fixture"))
        try Data("broken".utf8).write(to: third); XCTAssertTrue(try FinderMoveRecords.pending(in: root, expectedBinding: "fixture"))
    }
    func testDurablePreparationRefusalReleasesOnlyAValidatedNoWorkReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("move-2.json", isDirectory: false)
        let base: [String: Any] = ["version": 1, "id": String(repeating: "1", count: 32), "binding": "fixture", "exclusive": true,
            "source": "Documents/A", "destination": "Archive/A", "complete": false, "failed": true, "requestID": "rc:fixture",
            "failureKind": "destinationExists", "objects": NSNull(), "directories": NSNull()]
        func write(_ changes: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new }).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try write([:]); XCTAssertFalse(try FinderMoveRecords.pending(in: root, expectedBinding: "fixture"))
        XCTAssertTrue(FinderMoveRecords.recordedRoutes(in: root, expectedBinding: "fixture").isEmpty)
        for changes: [String: Any] in [["binding": "wrong"], ["id": "bad"], ["requestID": ""], ["complete": true], ["preparing": true], ["appleDouble": true], ["exclusive": false],
                                        ["objects": [["source": "Documents/A"]]], ["directories": ["Documents"]], ["destination": "documents/a/sub"]] {
            try write(changes); XCTAssertTrue(try FinderMoveRecords.pending(in: root, expectedBinding: "fixture"))
        }
    }
    func testOccupiedDestinationFailureIsVisibleBesideCompletedJob() throws {
        var completed: [String: Any] = ["id": "first", "source": "a", "destination": "b", "phase": "completed", "message": "", "active": false,
            "needsRecovery": false, "total": 1, "completed": 1]
        let failed = completed.merging(["id": "second", "source": "c", "destination": "d", "phase": "failed", "failureKind": "destinationExists"]) { _, new in new }
        completed["message"] = "Complete"
        let snapshot = try FinderMoveStatus.decode(response(["phase": "completed", "jobs": [completed, failed]]))
        XCTAssertTrue(snapshot.safeToStop); XCTAssertTrue(snapshot.hasFailedJobs); XCTAssertTrue(snapshot.recoverableJobs.isEmpty)
        XCTAssertTrue(snapshot.displayMessage.contains("already exists")); XCTAssertTrue(snapshot.displayMessage.contains("new move"))
    }
    func testRetainedRecordsBlockNewDirectWriterUntilComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(try FinderMoveRecords.pending(in: root))
        let file = root.appendingPathComponent("move.json")
        try Data("{\"version\":1,\"complete\":false}".utf8).write(to: file)
        XCTAssertTrue(try FinderMoveRecords.pending(in: root))
        try Data("{\"version\":1,\"complete\":true}".utf8).write(to: file)
        XCTAssertFalse(try FinderMoveRecords.pending(in: root))
        try Data("{\"version\":1,\"complete\":1}".utf8).write(to: file)
        XCTAssertTrue(try FinderMoveRecords.pending(in: root))
        try Data("{}".utf8).write(to: file)
        XCTAssertTrue(try FinderMoveRecords.pending(in: root))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root)
        XCTAssertTrue(try FinderMoveRecords.pending(in: root))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertTrue(try FinderMoveRecords.pending(in: root))
    }
}

extension FinderMoveTests {
    func testDriveMoveRequestKeepsBothEndpointsOnTheSelectedVolume() throws {
        let root = URL(fileURLWithPath: "/Volumes/Drive", isDirectory: true)
        let item = root.appendingPathComponent("Logic Projects", isDirectory: true)
        let target = root.appendingPathComponent("T5 Backup", isDirectory: true)
        let request = try DriveMoveRequest(source: item, folder: target, under: root)
        XCTAssertEqual(request.source, "Logic Projects")
        XCTAssertEqual(request.destination, "T5 Backup/Logic Projects")
        XCTAssertNotNil(UUID(uuidString: request.requestID))
        let keepBoth = try DriveMoveRequest(source: item, folder: target, under: root, name: "Logic Projects (2)")
        XCTAssertEqual(keepBoth.destination, "T5 Backup/Logic Projects (2)")
        XCTAssertThrowsError(try DriveMoveRequest(source: item, folder: target, under: root, name: "../escape"))
        XCTAssertThrowsError(try DriveMoveRequest(source: item, folder: item, under: root))
        XCTAssertThrowsError(try DriveMoveRequest(source: item, folder: root, under: root))
        XCTAssertThrowsError(try DriveMoveRequest(source: root, folder: target, under: root))
        XCTAssertThrowsError(try DriveMoveRequest(source: item, folder: URL(fileURLWithPath: "/Volumes/Drive 2"), under: root))
        let backToRoot = try DriveMoveRequest(source: target.appendingPathComponent("Demo.wav"), folder: root, under: root)
        XCTAssertEqual(backToRoot.destination, "Demo.wav")
    }
}
