import XCTest
import Darwin
import CryptoKit
@testable import CloudDrive

/// Real NFS fixtures only: never reads the owner's connection or application-support directory.
@MainActor final class DriveLifecycleTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testUnfinishedMoveBlocksDirectWriterAndRetainsWorkerOnEject() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover()
        try FileManager.default.createDirectory(at: drive.moveDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journal: [String: Any] = ["version": 1, "id": String(repeating: "a", count: 32),
            "binding": drive.connection.fingerprint, "source": "before", "destination": "after",
            "directory": false, "complete": false,
            "objects": [["source": "before", "destination": "after", "size": 0]], "directories": []]
        try JSONSerialization.data(withJSONObject: journal).write(to: drive.moveDirectory.appendingPathComponent("move.json"))
        await drive.refreshMoveRecords()
        XCTAssertFalse(drive.canDirectUpload)
        XCTAssertTrue(drive.canConnect, "Finder recovery must remain available for retained move records")
        await drive.start()
        XCTAssertTrue(drive.mounted, drive.operationResult)
        await drive.refresh()
        XCTAssertEqual(drive.finderMoves?.needsRecovery, true)
        XCTAssertFalse(drive.canVerifyBucket)
        await drive.verifyBucket()
        XCTAssertFalse(drive.lastOperationFailed)
        XCTAssertTrue(drive.operationResult.contains("awaiting recovery"))
        XCTAssertNil(drive.receipt)
        let record = try f.record()
        await drive.eject()
        XCTAssertTrue(record.process.matchesRunningProcess(), "An empty upload queue must not terminate an unresolved move worker")
        XCTAssertNotNil(try? f.record())
        XCTAssertFalse(drive.canQuit)
        XCTAssertFalse(drive.canDirectUpload)
        XCTAssertTrue(drive.operationResult.contains("Resume move"), drive.operationResult)
    }

    func testEjectDetachesActiveMoveWithEmptyUploadQueueAndStopsOnlyAfterIdle() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start()
        XCTAssertTrue(drive.mounted, drive.operationResult)
        let original = try f.record()
        var status = FinderMoveStatus(version: 1, enabled: true, active: true, needsRecovery: false,
            phase: .preparing, completed: 16, total: 107, message: "Synthetic long move")
        drive.finderMoveStatusForTesting = { status }
        await drive.refresh()
        XCTAssertEqual(drive.uploads, .idle, "An empty upload queue does not prove an active move is safe to stop")
        XCTAssertFalse(drive.canVerifyBucket)
        await drive.verifyBucket()
        XCTAssertNil(drive.receipt)
        XCTAssertFalse(drive.lastOperationFailed)
        XCTAssertTrue(drive.operationResult.contains("Finder browsing may also wait"))
        XCTAssertTrue(original.process.matchesRunningProcess())
        let started = ContinuousClock.now
        await drive.eject()
        XCTAssertLessThan(started.duration(to: .now), .seconds(3), "Eject must detach instead of waiting for cloud work")
        XCTAssertFalse(drive.busy)
        XCTAssertFalse(drive.mounted)
        XCTAssertNil(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()))
        XCTAssertTrue(drive.running)
        XCTAssertFalse(drive.lastOperationFailed, drive.operationResult)
        XCTAssertFalse(drive.canQuit)
        XCTAssertFalse(drive.canConnect)
        XCTAssertFalse(drive.canDirectUpload)
        for _ in 0..<3 {
            await drive.refresh()
            XCTAssertTrue(original.process.matchesRunningProcess())
            XCTAssertEqual(try f.record().sessionID, original.sessionID)
            XCTAssertEqual(drive.finderMoves?.completed, 16)
            XCTAssertEqual(drive.finderMoves?.total, 107)
            XCTAssertFalse(drive.lastOperationFailed, drive.operationResult)
        }
        // Cross the former fixed drain deadline while the detached move remains
        // active. This must stay normal background progress, with no false error.
        try await Task.sleep(for: .seconds(31))
        await drive.refresh()
        XCTAssertFalse(drive.busy)
        XCTAssertFalse(drive.mounted)
        XCTAssertTrue(original.process.matchesRunningProcess())
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        XCTAssertEqual(drive.finderMoves?.phase, .preparing)
        XCTAssertFalse(drive.lastOperationFailed, drive.operationResult)
        XCTAssertFalse(drive.canQuit)
        status = FinderMoveStatus(version: 1, enabled: true, active: false, needsRecovery: false,
            phase: .completed, completed: 107, total: 107, message: "")
        try await waitForWorkerRetirement(drive)
        XCTAssertFalse(original.process.matchesRunningProcess())
        XCTAssertNil(try WorkerRecordStore(directory: f.root).load())
    }

    func testMixedMoveJobsRetainDetachedWorkerUntilLastRecoverableJobClears() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start()
        XCTAssertTrue(drive.mounted, drive.operationResult)
        let owned = try f.record()
        let active = FinderMoveStatus.Job(id: "moving", source: "A", destination: "B", active: true, needsRecovery: false,
            phase: .copying, completed: 1, total: 5, message: "")
        let interrupted = FinderMoveStatus.Job(id: "interrupted", source: "C", destination: "D", active: false, needsRecovery: true,
            phase: .needsRecovery, completed: 2, total: 8, message: "")
        var sample = FinderMoveStatus(version: 1, enabled: true, active: true, needsRecovery: true,
            phase: .copying, completed: 1, total: 5, message: "", jobs: [active, interrupted])
        drive.finderMoveStatusForTesting = { sample }
        await drive.refresh(); await drive.eject()
        XCTAssertFalse(drive.mounted); XCTAssertTrue(drive.running); XCTAssertTrue(drive.canResumeMove)
        sample = FinderMoveStatus(version: 1, enabled: true, active: false, needsRecovery: true,
            phase: .needsRecovery, completed: 2, total: 8, message: "", jobs: [interrupted])
        await drive.refresh()
        XCTAssertTrue(owned.process.matchesRunningProcess()); XCTAssertFalse(drive.canQuit); XCTAssertFalse(drive.canDirectUpload)
        sample = FinderMoveStatus(version: 1, enabled: true, active: false, needsRecovery: false,
            phase: .idle, completed: 0, total: 0, message: "", jobs: [])
        try await waitForWorkerRetirement(drive)
        XCTAssertFalse(owned.process.matchesRunningProcess())
    }

    func testLegacyIdleSampleCannotRetireWorkerOverSecondaryMoveJournal() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start()
        let owned = try f.record()
        let secondary = drive.moveDirectory.appendingPathComponent("move-1.json", isDirectory: false)
        try FileManager.default.createDirectory(at: drive.moveDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "complete": false, "binding": drive.connection.fingerprint])
        try data.write(to: secondary)
        drive.finderMoveStatusForTesting = { FinderMoveStatus(version: 1, enabled: true, active: false, needsRecovery: false,
            phase: .idle, completed: 0, total: 0, message: "") }
        await drive.eject()
        XCTAssertTrue(owned.process.matchesRunningProcess()); XCTAssertFalse(drive.canQuit)
        XCTAssertEqual(try f.record().sessionID, owned.sessionID)
        XCTAssertTrue(drive.operationResult.contains("saved Finder move"), drive.operationResult)
        try FileManager.default.removeItem(at: secondary)
        try await waitForWorkerRetirement(drive)
    }

    func testDetachedMoveStatusFailureRetainsWorkerAndRecoveryRecords() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start()
        XCTAssertTrue(drive.mounted, drive.operationResult)
        let original = try f.record()
        var unavailable = false
        drive.finderMoveStatusForTesting = {
            if unavailable { throw RuntimeFailure.invalidControlResponse }
            return FinderMoveStatus(version: 1, enabled: true, active: true, needsRecovery: false,
                phase: .copying, completed: 1, total: 2, message: "Synthetic move")
        }
        await drive.eject()
        XCTAssertFalse(drive.mounted)
        unavailable = true
        await drive.refresh()
        XCTAssertTrue(original.process.matchesRunningProcess(), "Unknown move status must never authorize shutdown")
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        XCTAssertFalse(drive.canQuit)
        XCTAssertFalse(drive.canConnect)
    }

    func testFinderChangesAutomaticallyUpdateSearchWithoutCatalogRefresh() async throws {
        let f = try fixture(), drive = f.controller()
        drive.connection = Connection(endpoint:"https://native-fixture.r2.cloudflarestorage.com",bucket:"fixture",prefix:"prefix",accessKey:"synthetic",secretKey:"synthetic")
        await drive.recover(); await drive.start(); XCTAssertTrue(drive.mounted,drive.operationResult)
        let remote = NativeMetadataFixture(source:f.source)
        // This test isolates targeted invalidations; periodic reconciliation has
        // separate coverage and must not race slower native RPC retry timings.
        let catalog = CatalogController(root:f.root,automaticInterval:.milliseconds(20),reconciliationInterval:3600,makeRemote:{ _ in remote })
        drive.installCatalogForTesting(catalog)
        // Bind the feed before the first automatic scan. Starting the scanner
        // first can finish a baseline before the new-session reconcile flag is
        // recorded, making a second baseline look like a file-triggered scan.
        let initialWorker = try f.record()
        let initialCursor = try await catalog.workerCursor()
        let initialBody = try JSONSerialization.data(withJSONObject:["after":initialCursor.sequence,"limit":256])
        let initialFeed = try await ControlClient(port:initialWorker.controlPort,token:initialWorker.controlToken).call(route:"vfs/metadata-changes",body:initialBody)
        try await catalog.recordWorkerChanges(initialFeed,after:initialCursor.sequence)
        catalog.enableAutomaticUpdates()
        defer { catalog.stopAutomaticUpdates() }
        // Authenticate/capture the worker feed before mutations, so a new-session
        // baseline cannot be mistaken for a targeted change update.
        await drive.refresh()
        try await waitForCatalog(drive:drive) { catalog.summary.lastCompleted != nil && !catalog.scanning }
        let original = f.root.appendingPathComponent("input.wav")
        try Data(repeating:73,count:65_536).write(to:original)
        let before = await remote.rootLists
        func command(_ executable:String,_ arguments:[String]) async throws {
            let result = try await CommandRunner.run(CommandSpec(executable:URL(fileURLWithPath:executable),arguments:arguments,timeout:10))
            XCTAssertEqual(result.exitCode,0)
        }
        try await command("/bin/cp",["-X",original.path,f.mount.appendingPathComponent("original.wav").path])
        try await waitForCatalog(drive:drive) { await catalog.search(CatalogQuery(text:"original")); return catalog.results.contains { $0.key == "prefix/original.wav" } }
        try await command("/bin/mv",[f.mount.appendingPathComponent("original.wav").path,f.mount.appendingPathComponent("renamed.wav").path])
        try await waitForCatalog(drive:drive) { await catalog.search(CatalogQuery(text:"renamed")); return catalog.results.contains { $0.key == "prefix/renamed.wav" } }
        await catalog.search(CatalogQuery(text:"original")); XCTAssertTrue(catalog.results.isEmpty)
        try await command("/bin/rm",[f.mount.appendingPathComponent("renamed.wav").path])
        try await waitForCatalog(drive:drive) { catalog.summary.count == 0 }
        let afterFiles = await remote.rootLists
        XCTAssertEqual(afterFiles,before,"Ordinary file changes must not cause a full-drive scan")
        try await command("/bin/mkdir",[f.mount.appendingPathComponent("Album").path])
        try await command("/bin/cp",["-X",original.path,f.mount.appendingPathComponent("Album/vocals.wav").path])
        try await waitForCatalog(drive:drive) { await catalog.search(CatalogQuery(text:"vocals")); return catalog.results.contains { $0.key == "prefix/Album/vocals.wav" } }
        try await command("/bin/mv",[f.mount.appendingPathComponent("Album").path,f.mount.appendingPathComponent("Renamed Album").path])
        try await waitForCatalog(drive:drive) { await catalog.search(CatalogQuery(text:"vocals")); return catalog.results.contains { $0.key == "prefix/Renamed Album/vocals.wav" } && !catalog.results.contains { $0.key == "prefix/Album/vocals.wav" } }
        let record = try f.record()
        let denied = ControlClient(port:record.controlPort,token:"invalid-fixture-token")
        do { _ = try await denied.call(route:"vfs/metadata-changes",body:Data("{\"after\":0,\"limit\":1}".utf8)); XCTFail("Metadata hints require authentication") } catch {}
        // Eject immediately after a copy: its drain can publish bytes after the
        // normal event poll stopped, so the final feed must be consumed before exit.
        try await command("/bin/cp",["-X",original.path,f.mount.appendingPathComponent("on-eject.wav").path])
        await drive.eject(); try await waitForWorkerRetirement(drive)
        try await waitForCatalog(drive:drive) { await catalog.search(CatalogQuery(text:"eject")); return catalog.results.contains { $0.key == "prefix/on-eject.wav" } }
        catalog.stopAutomaticUpdates()
    }
    /// An explicit cleanup eject can finish before all kernel/NFS observations
    /// agree. Retry a retained uncertain session only after its mount disappears.
    private func ejectFixtureAndWait(_ drive: Drive, fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        await drive.eject()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while MountInspector.exactEntry(at: fixture.mount.path, entries: try MountInspector.snapshot()) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(MountInspector.exactEntry(at: fixture.mount.path, entries: try MountInspector.snapshot()), drive.operationResult, file: file, line: line)
        if try WorkerRecordStore(directory: fixture.root).load()?.appDetachUncertain == true,
           MountInspector.exactEntry(at: fixture.mount.path, entries: try MountInspector.snapshot()) == nil {
            await drive.eject()
        }
        try await waitForWorkerRetirement(drive, file: file, line: line)
    }

    private func waitForWorkerRetirement(_ drive: Drive, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !drive.canQuit, ContinuousClock.now < deadline {
            await drive.refresh()
            if !drive.canQuit { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(drive.canQuit, drive.operationResult, file: file, line: line)
        XCTAssertFalse(drive.running, drive.operationResult, file: file, line: line)
        XCTAssertFalse(drive.mounted, drive.operationResult, file: file, line: line)
    }

    private func waitForCatalog(drive:Drive,file:StaticString = #filePath,line:UInt = #line,condition:@MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            await drive.refresh() // Worker status/event polling, never catalog Refresh.
            if try await condition() { return }
            try await Task.sleep(for:.milliseconds(50))
        }
        if let record = try? WorkerRecordStore(directory:drive.root).load() {
            if let data = try? await ControlClient(port:record.controlPort,token:record.controlToken).call(route:"vfs/metadata-changes",body:Data("{\"after\":0,\"limit\":256}".utf8)) {
                print("SYNTHETIC_METADATA_FEED",String(decoding:data,as:UTF8.self))
            }
        }
        print("SYNTHETIC_CATALOG_STATUS",drive.catalog.message,drive.catalog.automaticStatus,drive.catalog.summary.count)
        XCTFail("Finder mutation did not reach the local catalog automatically",file:file,line:line)
    }

    func testStartupWithoutSavedDriveStaysDisconnected() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(connectSavedDrive: true)
        XCTAssertTrue(drive.canConnect, drive.operationResult)
        XCTAssertEqual(drive.mountState, .disconnected)
        XCTAssertFalse(drive.running)
        XCTAssertFalse(drive.lastOperationFailed, drive.operationResult)
        XCTAssertNil(try WorkerRecordStore(directory: f.root).load())
        XCTAssertNil(try WorkerRecordStore(directory: f.root).loadIntent())
    }

    private func fixture() throws -> Fixture {
        let requestedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clouddrive-m1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let canonical = realpath(requestedRoot.path, nil) else { throw DriveError.message("Cannot canonicalize fixture root") }
        let root = URL(fileURLWithPath: String(cString: canonical)); free(canonical)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let packaged = ProcessInfo.processInfo.environment["CLOUDDRIVE_TEST_APP"].map { URL(fileURLWithPath: $0).appendingPathComponent("Contents/Resources") }
        let environment = ProcessInfo.processInfo.environment
        let backend = environment["CLOUDDRIVE_TEST_BACKEND"].map { URL(fileURLWithPath: $0) }
        let helper = environment["CLOUDDRIVE_TEST_HELPER"].map { URL(fileURLWithPath: $0) }
        let fixture = Fixture(
            root: root,
            source: source,
            binary: backend ?? packaged?.appendingPathComponent("rclone") ?? project.appendingPathComponent("build/backend/rclone"),
            helper: helper ?? packaged?.appendingPathComponent("CloudDriveHelper") ?? project.appendingPathComponent(".build/debug/CloudDriveHelper")
        )
        addTeardownBlock { await fixture.cleanup() }
        return fixture
    }

    func testUpdatedAppRecoversMountedWorkerAndEjectsWithoutOldBundle() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start()
        XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        XCTAssertTrue(original.process.executablePath.hasPrefix(f.root.appendingPathComponent("Workers").path))
        await first.relinquishForTesting()
        // The new app can have a different backend, or a missing old bundle.
        let updatedBinary = f.root.appendingPathComponent("new-app-rclone")
        try Data("different backend version".utf8).write(to: updatedBinary)
        let second = f.controller(binary: updatedBinary)
        await second.recover()
        XCTAssertTrue(second.mounted, second.operationResult)
        XCTAssertTrue(second.running, second.operationResult)
        XCTAssertEqual(try f.record().process, original.process)
        await second.refresh()
        XCTAssertEqual(second.mountState, .connected, second.operationResult)
        try await ejectFixtureAndWait(second, fixture: f)
        XCTAssertFalse(original.process.matchesRunningProcess())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.cachePath))
    }

    func testUpdatedAppRetiresEndedSessionWithoutOldBinary() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start()
        XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        await first.relinquishForTesting()
        // Model the prior app exiting before it retires its persistent record.
        // The updated app must recover this genuine ended session on its own.
        let mounted = try XCTUnwrap(MountInspector.exactEntry(at: f.mount.path, entries: MountInspector.snapshot()))
        guard mounted.id == original.mountID, mounted.type == "nfs", mounted.source == "127.0.0.1:/" else {
            return XCTFail("Fixture mount identity changed before shutdown")
        }
        let unmount = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [f.mount.path], timeout: 10))
        guard unmount.exitCode == 0, MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()) == nil,
              original.process.matchesRunningProcess() else { return XCTFail("Could not safely detach the fixture") }
        XCTAssertEqual(kill(original.process.pid, SIGTERM), 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !original.process.hasExited, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard original.process.hasExited else { return XCTFail("Fixture worker did not exit") }
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        try FileManager.default.removeItem(atPath: original.process.executablePath)
        let second = f.controller(binary: f.root.appendingPathComponent("new-app-rclone"))
        await second.recover()
        XCTAssertTrue(second.canConnect, second.operationResult)
        XCTAssertTrue(second.canQuit, second.operationResult)
        XCTAssertNil(try WorkerRecordStore(directory: f.root).load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.cachePath))
    }

    func testUnreachablePendingLaunchRemainsBlockedWithoutSecondWorker() async throws {
        let f = try fixture()
        let intent = LaunchIntent(sessionID: UUID(), executableSHA256: try WorkerRecord.digest(f.binary),
            destinationFingerprint: Connection().fingerprint, cachePath: f.root.appendingPathComponent("Cache/" + Connection().fingerprint).path,
            mountPath: f.mount.path, nfsPort: 63009, controlPort: 63010,
            controlToken: String(repeating: "fixture-token", count: 5), expectedRemote: f.source.path)
        try WorkerRecordStore(directory: f.root).saveIntent(intent)
        let drive = f.controller(); await drive.recover()
        XCTAssertFalse(drive.canConnect)
        XCTAssertEqual(drive.mountState, .blocked)
        XCTAssertEqual(try WorkerRecordStore(directory: f.root).loadIntent()?.sessionID, intent.sessionID)
        XCTAssertNil(try WorkerRecordStore(directory: f.root).load())
        await drive.start()
        XCTAssertNil(try WorkerRecordStore(directory: f.root).load())
        XCTAssertNil(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()))
        await drive.relinquishForTesting()
    }

    func testUploadLimitReadbackAndChangedRetryIdentity() async throws {
        let f = try fixture()
        let drive = f.controller()
        await drive.recover()
        await drive.start()
        XCTAssertTrue(drive.mounted, drive.operationResult)
        await drive.changeUploadLimit(.mbps5)
        XCTAssertEqual(drive.uploadLimit, .mbps5)
        XCTAssertEqual(drive.appliedUploadLimit, .mbps5)
        let record = try XCTUnwrap(try WorkerRecordStore(directory: f.root).load())
        let observed = try await ControlClient(port: record.controlPort, token: record.controlToken).uploadLimit()
        XCTAssertEqual(observed, .mbps5)
        await drive.refresh()
        await drive.retryUpload(UploadItem(id: 99999, name: "stale-fixture", size: 10, tries: 2, uploading: false), sessionID: record.sessionID)
        XCTAssertTrue(drive.operationResult.contains("changed or is already active"))
        XCTAssertTrue(record.process.matchesRunningProcess())
        await drive.recover()
        await drive.eject()
        XCTAssertTrue(drive.canQuit, drive.operationResult)
    }

    func testLiveUploadProgressUsesActualThrottledTransferAndClearsOnEject() async throws {
        let f = try fixture(), drive = f.controller(uploadLimitMiB: 1)
        await drive.recover(); await drive.start(); XCTAssertTrue(drive.mounted, drive.operationResult)
        let file = f.mount.appendingPathComponent("progress.bin")
        let write = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "of=" + file.path, "bs=1048576", "count=8"], timeout: 10, outputLimit: 0))
        XCTAssertEqual(write.exitCode, 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var sample: UploadProgressSnapshot?
        while ContinuousClock.now < deadline {
            await drive.refresh()
            if let snapshot = drive.uploadProgress,
               let row = snapshot.rows.first(where: { $0.name == "progress.bin" }),
               let bytes = row.bytes, bytes > 0 && bytes < 8_388_608,
               let speed = row.speed, speed > 0, snapshot.progress != nil, snapshot.eta != nil {
                sample = snapshot; break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let observed = try XCTUnwrap(sample, "Never received real partial upload progress and speed")
        let row = try XCTUnwrap(observed.rows.first(where: { $0.name == "progress.bin" }))
        XCTAssertEqual(row.size, 8_388_608)
        XCTAssertGreaterThan(try XCTUnwrap(row.progress), 0)
        XCTAssertLessThan(try XCTUnwrap(row.progress), 1)
        XCTAssertGreaterThan(try XCTUnwrap(observed.speed), 0)
        let original = try f.record()
        let ejectStarted = ContinuousClock.now
        await drive.eject()
        XCTAssertLessThan(ejectStarted.duration(to: .now), .seconds(3))
        XCTAssertFalse(drive.mounted)
        XCTAssertFalse(drive.busy)
        XCTAssertTrue(original.process.matchesRunningProcess(), "A partial upload must continue after Finder detaches")
        XCTAssertFalse(drive.canQuit)
        XCTAssertFalse(drive.lastOperationFailed, drive.operationResult)
        try await waitForWorkerRetirement(drive)
        XCTAssertNil(drive.uploadProgress)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.source.appendingPathComponent("progress.bin").path)[.size] as? Int, 8_388_608)
    }

    func testFreshInstallationCreatesPrivateStateAndCanConnect() async throws {
        let f = try fixture()
        let freshRoot = f.root.appendingPathComponent("fresh-install")
        let drive = Drive(root: freshRoot, binary: f.binary, helper: f.helper, fixtureSource: f.source, useKeychain: false, autoRecover: false)
        await drive.recover()
        XCTAssertTrue(drive.canConnect, drive.operationResult)
        let attributes = try FileManager.default.attributesOfItem(atPath: freshRoot.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        await drive.relinquishForTesting()
    }

    func testKilledUploadingWorkerRecoversPendingBytesFromSameCache() async throws {
        let f = try fixture(), drive = f.controller(uploadLimitMiB: 1)
        await drive.recover(); await drive.start()
        XCTAssertTrue(drive.mounted, drive.operationResult)
        let original = try f.record()
        let name = "pending-restart.bin", count = 8 * 1_048_576
        let write = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "of=" + f.mount.appendingPathComponent(name).path,
                        "bs=1048576", "count=8"], timeout: 10, outputLimit: 0))
        XCTAssertEqual(write.exitCode, 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var uploading = false
        while ContinuousClock.now < deadline {
            await drive.refresh()
            if let row = drive.uploadProgress?.rows.first(where: { $0.name == name }),
               let bytes = row.bytes, bytes > 0 && bytes < count {
                uploading = true; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(uploading, "Fixture must be interrupted during a real partial upload")
        guard uploading else { return }
        XCTAssertEqual(kill(original.process.pid, SIGKILL), 0)
        for _ in 0..<50 {
            if !original.process.matchesRunningProcess() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await drive.recover()
        XCTAssertFalse(drive.running)
        XCTAssertEqual(drive.uploads, .unknown)
        XCTAssertTrue(drive.canConnect, drive.operationResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(original.observedCachePath)))
        await drive.start()
        XCTAssertTrue(drive.mounted, drive.operationResult)
        XCTAssertEqual(try f.record().cachePath, original.cachePath)
        XCTAssertNotEqual(try f.record().sessionID, original.sessionID)
        await drive.eject()
        try await waitForWorkerRetirement(drive)
        let independentBytes = try Data(contentsOf: f.source.appendingPathComponent(name))
        XCTAssertEqual(independentBytes.count, count)
        XCTAssertEqual(SHA256.hash(data: independentBytes), SHA256.hash(data: Data(repeating: 0, count: count)))
    }

    func testRestartAdoptsSameWorkerAndDrainsPendingWriteBeforeReconnect() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); XCTAssertTrue(first.canConnect, first.operationResult)
        await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        let name = "clouddrive-check-" + UUID().uuidString + ".bin"
        let result = try await CommandRunner.run(CommandSpec(executable: f.helper, arguments: ["write", f.mount.path, name, "-"], timeout: 8))
        XCTAssertEqual(result.exitCode, 0)
        await first.relinquishForTesting()
        let updatedBinary = f.root.appendingPathComponent("updated-rclone")
        try FileManager.default.copyItem(at: f.binary, to: updatedBinary)
        let second = f.controller(binary: updatedBinary)
        await second.recover()
        XCTAssertTrue(second.running, second.operationResult); XCTAssertTrue(second.mounted, second.operationResult)
        XCTAssertEqual(try f.record().process.pid, original.process.pid)
        await second.eject()
        try await waitForWorkerRetirement(second)
        XCTAssertFalse(second.running, second.operationResult); XCTAssertFalse(second.mounted, second.operationResult)
        XCTAssertTrue(second.canConnect, second.operationResult)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(name)).count, 1_048_576)
        let expected = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let expectedBytes = (0..<16).reduce(into: Data()) { result, _ in result.append(expected) }
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: f.source.appendingPathComponent(name))), SHA256.hash(data: expectedBytes))
        XCTAssertFalse(original.process.matchesRunningProcess())
        await second.start(); XCTAssertTrue(second.mounted, second.operationResult)
        XCTAssertNotEqual(try f.record().sessionID, original.sessionID)
        try await ejectFixtureAndWait(second, fixture: f)
    }

    func testLaunchIntentReconstructsSameWorkerAcrossRecordPersistenceCrashGap() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        let store = try WorkerRecordStore(directory: f.root)
        let intent = LaunchIntent(sessionID: original.sessionID,
            executableSHA256: original.executableSHA256,
            destinationFingerprint: original.destinationFingerprint,
            cachePath: original.cachePath, mountPath: original.mountPath,
            nfsPort: original.nfsPort, controlPort: original.controlPort,
            controlToken: original.controlToken, expectedRemote: original.expectedRemote)
        // Simulate app death after launch but before the complete worker record was committed.
        try store.saveIntent(intent)
        try store.remove(expectedSessionID: original.sessionID)
        await first.relinquishForTesting()
        let second = f.controller(); await second.recover()
        XCTAssertTrue(second.running, second.operationResult)
        XCTAssertTrue(second.mounted, second.operationResult)
        let recovered = try f.record()
        XCTAssertEqual(recovered.sessionID, original.sessionID)
        XCTAssertEqual(recovered.process, original.process)
        XCTAssertEqual(recovered.cachePath, original.cachePath)
        XCTAssertEqual(recovered.observedFS, original.observedFS)
        XCTAssertEqual(recovered.observedCachePath, original.observedCachePath)
        XCTAssertEqual(recovered.mountID, original.mountID)
        XCTAssertNil(try store.loadIntent())
        try await ejectFixtureAndWait(second, fixture: f)
        XCTAssertFalse(second.running, second.operationResult)
        XCTAssertTrue(second.canConnect, second.operationResult)
        XCTAssertNil(try store.load()); XCTAssertNil(try store.loadIntent())
    }

    func testUnresponsiveWorkerCannotBeReportedAsSafelyEjected() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start(); XCTAssertTrue(drive.mounted, drive.operationResult)
        let original = try f.record()
        XCTAssertEqual(kill(original.process.pid, SIGSTOP), 0)
        defer { if original.process.matchesRunningProcess() { _ = kill(original.process.pid, SIGCONT) } }
        await drive.eject()
        XCTAssertTrue(original.process.matchesRunningProcess())
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        XCTAssertFalse(drive.canConnect)
        XCTAssertEqual(drive.uploads, .unknown)
        XCTAssertNotNil(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()))
        XCTAssertEqual(kill(original.process.pid, SIGCONT), 0)
        await drive.recover(); XCTAssertTrue(drive.running, drive.operationResult)
        try await ejectFixtureAndWait(drive, fixture: f)
    }

    func testMismatchedProcessStartCannotRetireLiveWorkerRecord() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        await first.relinquishForTesting()
        var changed = original; changed.process.startMicroseconds &+= 1
        try WorkerRecordStore(directory: f.root).save(changed)
        let second = f.controller(); await second.recover()
        XCTAssertFalse(second.canConnect)
        XCTAssertTrue(original.process.matchesRunningProcess())
        XCTAssertNotNil(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()))
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        try WorkerRecordStore(directory: f.root).save(original)
        await second.recover(); try await ejectFixtureAndWait(second, fixture: f)
    }

    func testVerificationReceiptIsClearedWhenDestinationChanges() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start(); XCTAssertTrue(drive.mounted, drive.operationResult)
        await drive.verifyBucket()
        XCTAssertNotNil(drive.receipt, drive.operationResult)
        let original = drive.connection
        drive.connection.prefix = "another-destination"
        XCTAssertNil(drive.receipt)
        drive.connection = original
        try await ejectFixtureAndWait(drive, fixture: f)
    }

    func testWrongControlTokenCannotAdoptEjectOrStartSecondWriter() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        await first.relinquishForTesting()
        var damaged = original; damaged.controlToken = "wrong-test-only-token-wrong-test-only-token"
        try WorkerRecordStore(directory: f.root).save(damaged)
        let second = f.controller(); await second.recover()
        XCTAssertFalse(second.running); XCTAssertFalse(second.canConnect)
        await second.start()
        XCTAssertEqual(try f.record().process, original.process)
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        await second.eject()
        XCTAssertTrue(original.process.matchesRunningProcess())
        XCTAssertEqual(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot())?.id, original.mountID)
        try WorkerRecordStore(directory: f.root).save(original)
        await second.recover(); XCTAssertTrue(second.running, second.operationResult)
        try await ejectFixtureAndWait(second, fixture: f)
        XCTAssertFalse(original.process.matchesRunningProcess())
        XCTAssertNil(try WorkerRecordStore(directory: f.root).load())
    }

    func testBusyEjectKeepsWorkerAndRecordUntilExplicitRetry() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start(); XCTAssertTrue(drive.mounted, drive.operationResult)
        let original = try f.record()
        let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/bin/sleep", isDirectory: false)
        holder.arguments = ["30"]; holder.currentDirectoryURL = f.mount
        try holder.run()
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        await drive.eject()
        XCTAssertTrue(drive.lastOperationFailed, drive.operationResult)
        XCTAssertTrue(original.process.matchesRunningProcess()); XCTAssertEqual(try f.record().appDetachUncertain, true)
        holder.terminate(); holder.waitUntilExit()
        // Even if subsequent table observations show genuine absence, a failed
        // in-app eject must survive polling and require another explicit eject.
        let external = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [f.mount.path], timeout: 10))
        XCTAssertEqual(external.exitCode, 0)
        for _ in 0..<7 { await drive.refresh(); try await Task.sleep(for: .seconds(1)) }
        XCTAssertTrue(original.process.matchesRunningProcess()); XCTAssertEqual(try f.record().sessionID, original.sessionID)
        try await ejectFixtureAndWait(drive, fixture: f)
    }
    func testSuccessfulExternalEjectRequiresStableAbsenceBeforeWorkerRetires() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start(); XCTAssertTrue(drive.mounted, drive.operationResult)
        let original = try f.record()
        let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [f.mount.path], timeout: 10))
        XCTAssertEqual(result.exitCode, 0)
        await drive.refresh(); XCTAssertTrue(original.process.matchesRunningProcess()); XCTAssertEqual(try f.record().sessionID, original.sessionID)
        try await waitForWorkerRetirement(drive)
    }

    func testUnmountedLiveWorkerRecoversWithoutStartingAnotherWorker() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [f.mount.path], timeout: 10))
        XCTAssertEqual(result.exitCode, 0)
        await first.relinquishForTesting()
        let second = f.controller(); await second.recover()
        XCTAssertTrue(second.running, second.operationResult); XCTAssertFalse(second.mounted)
        XCTAssertFalse(second.canConnect); XCTAssertTrue(second.canEject)
        XCTAssertEqual(try f.record().process.pid, original.process.pid)
        try await ejectFixtureAndWait(second, fixture: f)
        XCTAssertTrue(second.canConnect, second.operationResult)
    }

    func testSecondControllerCannotTakeOwnershipUntilFirstReleasesLock() async throws {
        let f = try fixture(), first = f.controller(), second = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        await second.recover(); XCTAssertFalse(second.canConnect)
        await second.start()
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        XCTAssertTrue(original.process.matchesRunningProcess())
        await first.eject(); await first.relinquishForTesting()
        await second.recover(); XCTAssertTrue(second.canConnect, second.operationResult)
    }

    func testKilledWorkerNeverReportsHealthyOrStartsOverStaleMount() async throws {
        let f = try fixture(), drive = f.controller()
        await drive.recover(); await drive.start(); XCTAssertTrue(drive.mounted, drive.operationResult)
        let original = try f.record()
        XCTAssertTrue(original.process.matchesRunningProcess())
        XCTAssertEqual(kill(original.process.pid, SIGKILL), 0)
        for _ in 0..<50 {
            if !original.process.matchesRunningProcess() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await drive.recover()
        XCTAssertFalse(drive.running, drive.operationResult)
        XCTAssertEqual(drive.uploads, .unknown)
        XCTAssertNil(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()), "Owned stale mount should be safely ejected")
        XCTAssertTrue(drive.canConnect, drive.operationResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Cache").path), "Recovery must preserve cache")
    }
}

@MainActor private final class Fixture {
    let root: URL, source: URL, binary: URL, helper: URL
    var mount: URL { root.appendingPathComponent("Drive") }
    private var drives = [Drive]()
    init(root: URL, source: URL, binary: URL, helper: URL) { self.root=root; self.source=source; self.binary=binary; self.helper=helper }
    func controller(uploadLimitMiB: Int? = nil, binary: URL? = nil) -> Drive {
        let drive = Drive(root: root, binary: binary ?? self.binary, helper: helper, fixtureSource: source, fixtureUploadLimitMiB: uploadLimitMiB, useKeychain: false, autoRecover: false)
        drives.append(drive); return drive
    }
    func record() throws -> WorkerRecord {
        guard let record = try WorkerRecordStore(directory: root).load() else { throw DriveError.message("Fixture worker record absent") }
        return record
    }
    func cleanup() async {
        // Only this UUID fixture may be touched. Never force-unmount or recursively remove a mounted path.
        for drive in drives where drive.canEject { await drive.eject() }
        guard let entries = try? MountInspector.snapshot() else { return }
        if MountInspector.exactEntry(at: mount.path, entries: entries) != nil {
            let result = try? await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [mount.path], timeout: 5))
            guard result?.exitCode == 0 else { return }
        }
        if let record = try? record(), record.process.matchesRunningProcess() {
            _ = kill(record.process.pid, SIGTERM)
            for _ in 0..<50 {
                if !record.process.matchesRunningProcess() { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !record.process.matchesRunningProcess() else { return }
        }
        for drive in drives { await drive.relinquishForTesting() }
        guard let after = try? MountInspector.snapshot(), MountInspector.exactEntry(at: mount.path, entries: after) == nil else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

/// The remote side of the isolated local-backend NFS fixture, not its mount.
private actor NativeMetadataFixture: ObjectInventoryRemote {
    let source: URL
    private(set) var rootLists = 0
    init(source:URL) { self.source = source }
    func head(key:String) async throws -> CatalogObject? {
        guard let url = CatalogText.mountURL(key:key,prefix:"prefix",mount:source) else { throw CatalogFailure.invalidInventory }
        var info = stat()
        if lstat(url.path,&info) != 0 {
            if errno == ENOENT { return nil }; throw CatalogFailure.storage
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        return CatalogObject(key:key,size:Int64(info.st_size),modified:Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec)),etag:"fixture-\(info.st_size)-\(info.st_mtimespec.tv_nsec)")
    }
    func isMissing(key:String) async throws -> Bool { try await head(key:key) == nil }
    func list(token:String?) async throws -> InventoryPage { rootLists += 1; return try await list(scope:"prefix/",token:token) }
    func list(scope:String,token:String?) async throws -> InventoryPage {
        var objects: [CatalogObject] = []
        if let enumerator = FileManager.default.enumerator(at:source,includingPropertiesForKeys:[.isRegularFileKey]) {
            while let url = enumerator.nextObject() as? URL {
                let key = "prefix/" + String(url.path.dropFirst(source.path.count+1))
                if key.utf8.starts(with:scope.utf8), let object = try await head(key:key) { objects.append(object) }
            }
        }
        return InventoryPage(objects:objects,nextToken:nil)
    }
}
