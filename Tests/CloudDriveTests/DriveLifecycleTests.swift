import XCTest
import Darwin
import CryptoKit
@testable import CloudDrive

/// Real NFS fixtures only: never reads the owner's connection or application-support directory.
@MainActor final class DriveLifecycleTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

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
        first.relinquishForTesting()
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
        await second.eject()
        XCTAssertTrue(second.canQuit, second.operationResult)
        XCTAssertFalse(original.process.matchesRunningProcess())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.cachePath))
    }

    func testUpdatedAppRetiresEndedSessionWithoutOldBinary() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start()
        XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        await first.eject(); XCTAssertTrue(first.canQuit, first.operationResult)
        first.relinquishForTesting()
        try WorkerRecordStore(directory: f.root).save(original)
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
        drive.relinquishForTesting()
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
        await drive.eject()
        XCTAssertTrue(drive.canQuit, drive.operationResult)
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
        drive.relinquishForTesting()
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
        XCTAssertTrue(drive.canQuit, drive.operationResult)
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
        first.relinquishForTesting()
        let updatedBinary = f.root.appendingPathComponent("updated-rclone")
        try FileManager.default.copyItem(at: f.binary, to: updatedBinary)
        let second = f.controller(binary: updatedBinary)
        await second.recover()
        XCTAssertTrue(second.running, second.operationResult); XCTAssertTrue(second.mounted, second.operationResult)
        XCTAssertEqual(try f.record().process.pid, original.process.pid)
        await second.eject()
        XCTAssertFalse(second.running, second.operationResult); XCTAssertFalse(second.mounted, second.operationResult)
        XCTAssertTrue(second.canConnect, second.operationResult)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(name)).count, 1_048_576)
        let expected = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let expectedBytes = (0..<16).reduce(into: Data()) { result, _ in result.append(expected) }
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: f.source.appendingPathComponent(name))), SHA256.hash(data: expectedBytes))
        XCTAssertFalse(original.process.matchesRunningProcess())
        await second.start(); XCTAssertTrue(second.mounted, second.operationResult)
        XCTAssertNotEqual(try f.record().sessionID, original.sessionID)
        await second.eject(); XCTAssertTrue(second.canQuit, second.operationResult)
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
        first.relinquishForTesting()
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
        await second.eject()
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
        await drive.eject(); XCTAssertTrue(drive.canQuit, drive.operationResult)
    }

    func testMismatchedProcessStartCannotRetireLiveWorkerRecord() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        first.relinquishForTesting()
        var changed = original; changed.process.startMicroseconds &+= 1
        try WorkerRecordStore(directory: f.root).save(changed)
        let second = f.controller(); await second.recover()
        XCTAssertFalse(second.canConnect)
        XCTAssertTrue(original.process.matchesRunningProcess())
        XCTAssertNotNil(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()))
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        try WorkerRecordStore(directory: f.root).save(original)
        await second.recover(); await second.eject()
        XCTAssertTrue(second.canQuit, second.operationResult)
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
        await drive.eject(); XCTAssertTrue(drive.canQuit, drive.operationResult)
    }

    func testWrongControlTokenCannotAdoptEjectOrStartSecondWriter() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        first.relinquishForTesting()
        var damaged = original; damaged.controlToken = "wrong-test-only-token-wrong-test-only-token"
        try WorkerRecordStore(directory: f.root).save(damaged)
        let second = f.controller(); await second.recover()
        XCTAssertFalse(second.running); XCTAssertFalse(second.canConnect)
        await second.eject()
        XCTAssertTrue(original.process.matchesRunningProcess())
        XCTAssertNotNil(MountInspector.exactEntry(at: f.mount.path, entries: try MountInspector.snapshot()))
        try WorkerRecordStore(directory: f.root).save(original)
        await second.recover(); XCTAssertTrue(second.running, second.operationResult)
        await second.eject(); XCTAssertFalse(second.running, second.operationResult)
    }

    func testUnmountedLiveWorkerRecoversWithoutStartingAnotherWorker() async throws {
        let f = try fixture(), first = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [f.mount.path], timeout: 10))
        XCTAssertEqual(result.exitCode, 0)
        first.relinquishForTesting()
        let second = f.controller(); await second.recover()
        XCTAssertTrue(second.running, second.operationResult); XCTAssertFalse(second.mounted)
        XCTAssertFalse(second.canConnect); XCTAssertTrue(second.canEject)
        XCTAssertEqual(try f.record().process.pid, original.process.pid)
        await second.eject(); XCTAssertTrue(second.canConnect, second.operationResult)
    }

    func testSecondControllerCannotTakeOwnershipUntilFirstReleasesLock() async throws {
        let f = try fixture(), first = f.controller(), second = f.controller()
        await first.recover(); await first.start(); XCTAssertTrue(first.mounted, first.operationResult)
        let original = try f.record()
        await second.recover(); XCTAssertFalse(second.canConnect)
        await second.start()
        XCTAssertEqual(try f.record().sessionID, original.sessionID)
        XCTAssertTrue(original.process.matchesRunningProcess())
        await first.eject(); first.relinquishForTesting()
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
        drives.forEach { $0.relinquishForTesting() }
        guard let after = try? MountInspector.snapshot(), MountInspector.exactEntry(at: mount.path, entries: after) == nil else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
