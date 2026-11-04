import XCTest
import Darwin
@testable import CloudDrive

final class WorkerIdentityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clouddrive-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func fixture() throws -> WorkerRecord {
        let process = try ProcessIdentity.capture(pid: getpid())
        return WorkerRecord(sessionID: UUID(), process: process,
            executableSHA256: try WorkerRecord.digest(URL(fileURLWithPath: process.executablePath)),
            destinationFingerprint: "fixture-destination", cachePath: "/tmp/fixture-cache", mountPath: "/tmp/fixture-mount",
            nfsPort: 62001, controlPort: 62002, controlToken: String(repeating: "x", count: 64), expectedRemote: "fixture:/")
    }
    func testProcessIdentityRejectsReusedPID() throws {
        let live = try ProcessIdentity.capture(pid: getpid())
        XCTAssertTrue(live.matchesRunningProcess())
        XCTAssertFalse(live.hasExited)
        var reused = live; reused.startMicroseconds &+= 1
        XCTAssertFalse(reused.matchesRunningProcess())
        XCTAssertFalse(reused.hasExited)
        XCTAssertThrowsError(try ProcessIdentity.capture(pid: -1))
    }
    func testValidationRejectsWrongDestinationAndStaleProcess() throws {
        var record = try fixture()
        let binary = URL(fileURLWithPath: record.process.executablePath)
        XCTAssertNoThrow(try record.validate(binary: binary, destinationFingerprint: record.destinationFingerprint,
            cachePath: record.cachePath, mountPath: record.mountPath))
        XCTAssertThrowsError(try record.validate(binary: binary, destinationFingerprint: "different",
            cachePath: record.cachePath, mountPath: record.mountPath))
        record.process.startMicroseconds &+= 1
        XCTAssertThrowsError(try record.validate(binary: binary, destinationFingerprint: record.destinationFingerprint,
            cachePath: record.cachePath, mountPath: record.mountPath))
        XCTAssertNoThrow(try record.validate(binary: binary, destinationFingerprint: record.destinationFingerprint,
            cachePath: record.cachePath, mountPath: record.mountPath, requireRunning: false))
    }
    func testSessionOwnershipDoesNotDependOnNewAppBinary() throws {
        var record = try fixture()
        XCTAssertNoThrow(try record.validateSession(destinationFingerprint: record.destinationFingerprint,
            cachePath: record.cachePath, mountPath: record.mountPath))
        XCTAssertThrowsError(try record.validateSession(destinationFingerprint: "other",
            cachePath: record.cachePath, mountPath: record.mountPath))
        XCTAssertThrowsError(try record.validateSession(destinationFingerprint: record.destinationFingerprint,
            cachePath: "/other-cache", mountPath: record.mountPath))
        record.process.startMicroseconds &+= 1
        XCTAssertThrowsError(try record.validateSession(destinationFingerprint: record.destinationFingerprint,
            cachePath: record.cachePath, mountPath: record.mountPath))
    }

    func testStagedExecutableSurvivesBundleReplacement() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundled-rclone")
        try Data("old backend".utf8).write(to: source)
        let old = try WorkerExecutable.stage(source, root: root)
        XCTAssertEqual(try WorkerExecutable.stage(source, root: root), old)
        try Data("updated backend".utf8).write(to: source)
        let updated = try WorkerExecutable.stage(source, root: root)
        XCTAssertNotEqual(old, updated)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old backend")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try String(contentsOf: updated, encoding: .utf8), "updated backend")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.path)
        try Data("tampered".utf8).write(to: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: old.path)
        try Data("old backend".utf8).write(to: source)
        XCTAssertThrowsError(try WorkerExecutable.stage(source, root: root))
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "tampered")
    }

    func testMountNeedsExactFilesystemIdentityAndSource() throws {
        var record = try fixture(); record.mountID = "123:456"
        let entry = MountEntry(path: record.mountPath, source: "127.0.0.1:/", type: "nfs", id: "123:456")
        XCTAssertTrue(try MountInspector.validateOwnedMount(record: record, entries: [entry]))
        XCTAssertFalse(try MountInspector.validateOwnedMount(record: record, entries: []))
        var foreign = entry; foreign.id = "999:999"
        XCTAssertThrowsError(try MountInspector.validateOwnedMount(record: record, entries: [foreign]))
        foreign = entry; foreign.source = "other-host:/"
        XCTAssertThrowsError(try MountInspector.validateOwnedMount(record: record, entries: [foreign]))
        foreign = entry; foreign.type = "apfs"
        XCTAssertThrowsError(try MountInspector.validateOwnedMount(record: record, entries: [foreign]))
        record.mountID = nil
        XCTAssertThrowsError(try MountInspector.validateOwnedMount(record: record, entries: [entry]))
    }
    func testKernelMountSnapshotDoesNotNeedTargetPath() throws {
        let entries = try MountInspector.snapshot()
        XCTAssertTrue(entries.contains { $0.path == "/" })
        XCTAssertNil(MountInspector.exactEntry(at: "/unreachable/nonexistent/path", entries: entries))
    }
    func testRecordRoundTripPrivatePermissionsAndSessionBoundRemoval() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkerRecordStore(directory: directory); let record = try fixture()
        XCTAssertNil(try store.load()); try store.save(record)
        XCTAssertEqual(try store.load(), record)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("worker.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try store.remove(expectedSessionID: UUID()))
        XCTAssertEqual(try store.load(), record)
        try store.remove(expectedSessionID: record.sessionID); XCTAssertNil(try store.load())
    }
    func testMalformedLegacyRecordIsNotAdopted() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worker.json")
        try Data("{\"pid\":123,\"port\":5572,\"password\":\"legacy\"}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try WorkerRecordStore(directory: directory).load())
    }
    func testSymlinkRecordAndLockAreRejectedWithoutTouchingTarget() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("preserve")
        try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("worker.json"), withDestinationURL: outside)
        let store = try WorkerRecordStore(directory: directory)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(fixture()))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("owner.lock"), withDestinationURL: outside)
        XCTAssertThrowsError(try OwnerLock(directory: directory))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "unchanged")
    }
    func testPublicRecordPermissionsAndUnsafeDirectoryAreRejected() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkerRecordStore(directory: directory); try store.save(fixture())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent("worker.json").path)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try OwnerLock(directory: directory))
        XCTAssertThrowsError(try WorkerRecordStore(directory: directory))
    }
    func testFIFORecordIsRejectedWithoutWaitingForWriter() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("worker.json").path, 0o600), 0)
        let store = try WorkerRecordStore(directory: directory)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(fixture()))
    }
    func testOwnerLockPreventsSecondControllerAndReleases() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var first: OwnerLock? = try OwnerLock(directory: directory)
        try withExtendedLifetime(first) { XCTAssertThrowsError(try OwnerLock(directory: directory)) }
        first = nil
        XCTAssertNoThrow(try OwnerLock(directory: directory))
    }
    func testLaunchIntentRoundTripAndSessionBoundRetirement() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkerRecordStore(directory: directory); let record = try fixture()
        let intent = LaunchIntent(sessionID: record.sessionID, executableSHA256: record.executableSHA256,
            destinationFingerprint: record.destinationFingerprint, cachePath: record.cachePath, mountPath: record.mountPath,
            nfsPort: record.nfsPort, controlPort: record.controlPort, controlToken: record.controlToken, expectedRemote: record.expectedRemote)
        try store.saveIntent(intent); XCTAssertEqual(try store.loadIntent(), intent)
        XCTAssertEqual(intent.record(process: record.process), record)
        XCTAssertThrowsError(try store.removeIntent(expectedSessionID: UUID()))
        try store.removeIntent(expectedSessionID: intent.sessionID); XCTAssertNil(try store.loadIntent())
    }
}
