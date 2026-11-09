import XCTest
import Foundation
import Darwin
@testable import CloudDriveCore
@testable import CloudDrive

private actor NamespaceSampleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class NamespaceLifecycleTests: XCTestCase {
    func testReconnectReusesOnlyPrivateEmptyMountpoint() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let mount = parent.appendingPathComponent("Volume")
        try NamespaceDriveController.prepareMountDirectory(mount)
        try NamespaceDriveController.prepareMountDirectory(mount)
        let local = mount.appendingPathComponent("local.txt")
        try Data("preserved".utf8).write(to: local)
        XCTAssertThrowsError(try NamespaceDriveController.prepareMountDirectory(mount))
        XCTAssertEqual(try Data(contentsOf: local), Data("preserved".utf8))
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mount)
        XCTAssertThrowsError(try NamespaceDriveController.prepareMountDirectory(link))
    }
    private struct Fixture {
        let root: URL
        let remoteDirectory: URL
        let connection: Connection
        let binary: URL
    }
    private func fixture() throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["CLOUDDRIVE_TEST_ENGINE"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent(".build/debug/CloudDriveEngine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build CloudDriveEngine before running lifecycle qualification.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return Fixture(root: root, remoteDirectory: root.appendingPathComponent("Remote"),
            connection: .init(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "fixture", accessKey: "synthetic", secretKey: "synthetic"), binary: binary)
    }
    private func controller(_ fixture: Fixture, binary: URL? = nil) -> NamespaceDriveController {
        let value = NamespaceDriveController(root: fixture.root, engineBinary: binary ?? fixture.binary, fixtureRemoteDirectory: fixture.remoteDirectory)
        value.legacySafetyCheck = { true }; value.configure(fixture.connection); return value
    }
    private func seed(_ fixture: Fixture) async throws {
        let remote = try FixtureStorageRemote(directory: fixture.remoteDirectory)
        _ = try await remote.put(key: "fixture/Folder/file.txt", data: Data("original fixture bytes".utf8), condition: .absent, operationID: UUID())
    }
    private func session(_ fixture: Fixture) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("namespace-owner.json"))) as? [String: Any])
    }
    private func identity(_ fixture: Fixture) throws -> ProcessIdentity {
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(try session(fixture)["identity"]))
        return try JSONDecoder().decode(ProcessIdentity.self, from: data)
    }
    private func awaitRetirement(_ value: NamespaceDriveController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while value.hasSession && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }
    private func cleanup(_ value: NamespaceDriveController, fixture: Fixture) async {
        value.mountSnapshotForTesting = nil; value.rpcFailureForTesting = nil; value.beforeStatusPublishForTesting = nil
        if value.hasSession {
            if !value.running { await value.recover() }
            await value.eject()
        }
        if !value.hasSession { try? FileManager.default.removeItem(at: fixture.root) }
    }
    func testReadOnlyPreviewImportsMetadataAndStopsOnlyItsIdleFixtureWorker() async throws {
        let fixture = try fixture(); try await seed(fixture)
        let value = controller(fixture)
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        XCTAssertTrue(value.running, value.error); XCTAssertTrue(value.hasSession)
        guard value.running else { print("NAMESPACE_FIXTURE_DIAGNOSTICS " + fixture.root.path); return }
        XCTAssertTrue(value.readOnly); XCTAssertFalse(value.enabled); XCTAssertFalse(value.canMount)
        let worker = try identity(fixture)
        await value.importMetadata()
        XCTAssertEqual(value.importProgress?.objects, 1); XCTAssertEqual(value.importProgress?.complete, true)
        XCTAssertTrue(value.canMount); XCTAssertTrue(value.canEnable)
        await value.eject()
        let retirementDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while value.hasSession && ContinuousClock.now < retirementDeadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(value.running, value.error); XCTAssertFalse(value.hasSession); XCTAssertTrue(worker.hasExited)
        guard !value.hasSession else { print("NAMESPACE_FIXTURE_DIAGNOSTICS " + fixture.root.path); return }
        let remote = try FixtureStorageRemote(directory: fixture.remoteDirectory)
        let object = try await remote.head(key: "fixture/Folder/file.txt")
        XCTAssertNotNil(object)
        try FileManager.default.removeItem(at: fixture.root)
    }
    func testCorruptCapabilityNeverLaunchesWritableOrClearsRecords() async throws {
        let fixture = try fixture(), directory = fixture.root.appendingPathComponent("Namespaces/" + fixture.connection.fingerprint)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("capability.json"), bytes = Data("not a capability".utf8)
        try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let value = controller(fixture)
        XCTAssertTrue(value.capabilityBlocked); XCTAssertTrue(value.ownsDestination); XCTAssertFalse(value.enabled)
        await value.recover(); await value.prepare(connection: fixture.connection, mode: .managed, legacySafe: true)
        XCTAssertFalse(value.running); XCTAssertFalse(value.hasSession)
        XCTAssertFalse(value.canEnable); XCTAssertFalse(value.canMount)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testSymlinkStagingDirectoryIsRejectedWithoutWritingItsTarget() async throws {
        let fixture = try fixture(), outside = fixture.root.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Engines"), withDestinationURL: outside)
        let value = controller(fixture)
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        XCTAssertFalse(value.running); XCTAssertFalse(value.hasSession); XCTAssertFalse(value.error.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testLaunchFailureRetiresOnlyItsUnstartedIntent() async throws {
        let fixture = try fixture(), broken = fixture.root.appendingPathComponent("NotAnExecutable")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("invalid executable format".utf8).write(to: broken)
        let value = controller(fixture, binary: broken)
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        XCTAssertFalse(value.running); XCTAssertFalse(value.hasSession); XCTAssertFalse(value.error.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("namespace-owner.json").path))
    }
    /// Simulate a crash between durable launch intent and process-identity save.
    /// Only this test's synthetic worker is terminated; its namespace is retained.
    private func interruptedLaunch(_ fixture: Fixture, previousBoot: Bool) async throws -> [String: Any] {
        try await seed(fixture)
        let first = controller(fixture)
        await first.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        XCTAssertTrue(first.running, first.error)
        await first.importMetadata()
        XCTAssertEqual(first.importProgress?.complete, true)
        let original = try session(fixture), worker = try identity(fixture)
        _ = try XCTUnwrap(original["bootSession"] as? String, "This host must expose a boot-session identity for this scenario")
        guard worker.matchesRunningProcess() else { throw POSIXError(.ESRCH) }
        XCTAssertEqual(kill(worker.pid, SIGKILL), 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !worker.hasExited && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(worker.hasExited)
        first.relinquishForTesting()
        var intent = original; intent.removeValue(forKey: "identity")
        if previousBoot { intent["bootSession"] = "completed-boot-" + UUID().uuidString }
        try writeSession(intent, fixture: fixture)
        let resource = try XCTUnwrap(URL(string: try XCTUnwrap(original["resource"] as? String)))
        // The worker has exited and this private socket resource belongs only to
        // the fixture. Remove it so recovery must reason from the launch intent.
        try FileManager.default.removeItem(at: resource)
        return original
    }
    private func writeSession(_ value: [String: Any], fixture: Fixture) throws {
        let path = fixture.root.appendingPathComponent("namespace-owner.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func testPreviousBootLaunchIntentWithoutIdentityRecoversReadOnlyAndPreservesNamespace() async throws {
        let fixture = try fixture()
        let original = try await interruptedLaunch(fixture, previousBoot: true)
        let recovered = controller(fixture)
        await recovered.recover()
        XCTAssertTrue(recovered.running, recovered.error)
        XCTAssertTrue(recovered.readOnly); XCTAssertFalse(recovered.enabled)
        XCTAssertEqual(recovered.importProgress?.complete, true)
        XCTAssertEqual(recovered.importProgress?.objects, 1)
        XCTAssertNotEqual(try session(fixture)["sessionID"] as? String, original["sessionID"] as? String)
        let worker = try identity(fixture)
        XCTAssertTrue(worker.matchesRunningProcess())
        let remote = try FixtureStorageRemote(directory: fixture.remoteDirectory)
        let originalObject = try await remote.head(key: "fixture/Folder/file.txt")
        XCTAssertEqual(originalObject?.size, Int64(Data("original fixture bytes".utf8).count))
        await cleanup(recovered, fixture: fixture)
        XCTAssertTrue(worker.hasExited)
    }
    func testSameBootUnknownLaunchIntentWithoutDescriptorIsPreservedWithoutRestart() async throws {
        let fixture = try fixture()
        let original = try await interruptedLaunch(fixture, previousBoot: false)
        let path = fixture.root.appendingPathComponent("namespace-owner.json"), before = try Data(contentsOf: path)
        let recovered = controller(fixture)
        await recovered.recover()
        XCTAssertFalse(recovered.running); XCTAssertTrue(recovered.hasSession)
        XCTAssertTrue(recovered.error.contains("Restart this Mac"), recovered.error)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertNil(try session(fixture)["identity"])
        // Restore the known exited identity solely to let normal cleanup retire
        // this fixture; never bypass the production unknown-launch safeguard.
        try writeSession(original, fixture: fixture); recovered.legacySafetyCheck = { false }
        await cleanup(recovered, fixture: fixture)
        XCTAssertFalse(recovered.hasSession)
    }
    func testPreviousBootUnknownLaunchIntentCannotReplaceForeignMount() async throws {
        let fixture = try fixture()
        let original = try await interruptedLaunch(fixture, previousBoot: true)
        let path = fixture.root.appendingPathComponent("namespace-owner.json"), before = try Data(contentsOf: path)
        let recovered = controller(fixture)
        recovered.mountSnapshotForTesting = { [MountEntry(path: recovered.mountpoint.path, source: "/foreign/resource", type: "clouddrive", id: "foreign")] }
        await recovered.recover()
        XCTAssertFalse(recovered.running); XCTAssertTrue(recovered.hasSession); XCTAssertFalse(recovered.error.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertNil(try session(fixture)["identity"])
        try writeSession(original, fixture: fixture); recovered.legacySafetyCheck = { false }
        await cleanup(recovered, fixture: fixture)
        XCTAssertFalse(recovered.hasSession)
    }
    func testUnknownStatusPreservesOwnedWorkerUntilAuthenticatedRetry() async throws {
        let fixture = try fixture(); let value = controller(fixture)
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        let worker = try identity(fixture)
        value.rpcFailureForTesting = { _ in POSIXError(.ETIMEDOUT) }
        await value.eject()
        XCTAssertTrue(value.hasSession); XCTAssertTrue(worker.matchesRunningProcess()); XCTAssertFalse(value.error.isEmpty)
        value.rpcFailureForTesting = nil
        await value.recover(); await value.eject(); try await awaitRetirement(value)
        XCTAssertFalse(value.hasSession, value.error); XCTAssertTrue(worker.hasExited)
        try FileManager.default.removeItem(at: fixture.root)
    }
    func testActivityFailureDoesNotMakeSyncStatusUnavailable() async throws {
        let fixture = try fixture(), value = controller(fixture)
        var activityAttempted = false
        value.rpcFailureForTesting = { operation in
            guard operation == "activity" else { return nil }
            activityAttempted = true
            return POSIXError(.ETIMEDOUT)
        }
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !activityAttempted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(activityAttempted)
        XCTAssertTrue(value.running)
        XCTAssertNotNil(value.status)
        XCTAssertNil(value.activitySampledAt)
        XCTAssertEqual(value.error, "")
        await cleanup(value, fixture: fixture)
    }
    func testStaleSuccessfulSampleCannotResurrectRetiredWorker() async throws {
        let fixture = try fixture(); let value = controller(fixture)
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        let worker = try identity(fixture), gate = NamespaceSampleGate()
        value.beforeStatusPublishForTesting = { [weak value] in value?.beforeStatusPublishForTesting = nil; await gate.pause() }
        let delayed = Task { try? await value.refreshForTesting() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let entered = await gate.entered; XCTAssertTrue(entered)
        await value.eject(); try await awaitRetirement(value)
        await gate.release(); await delayed.value
        XCTAssertFalse(value.running); XCTAssertFalse(value.hasSession); XCTAssertNil(value.status); XCTAssertTrue(worker.hasExited)
        try FileManager.default.removeItem(at: fixture.root)
    }
    func testRecoveryRejectsForeignMountWithoutTouchingItsOrOwnedWorker() async throws {
        let fixture = try fixture(), first = controller(fixture)
        await first.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        let worker = try identity(fixture), source = try session(fixture)["resource"] as? String
        XCTAssertNotNil(source)
        first.relinquishForTesting()
        let recovered = controller(fixture)
        recovered.mountSnapshotForTesting = { [MountEntry(path: recovered.mountpoint.path, source: "/unrelated/resource", type: "clouddrive", id: "foreign")] }
        await recovered.recover()
        XCTAssertFalse(recovered.running); XCTAssertFalse(recovered.mounted); XCTAssertTrue(recovered.hasSession)
        XCTAssertTrue(worker.matchesRunningProcess()); XCTAssertFalse(recovered.error.isEmpty)
        await cleanup(recovered, fixture: fixture)
        XCTAssertTrue(worker.hasExited)
    }
    func testNativeFinderEjectReconcilesMountAndRetiresIdleOwner() async throws {
        let fixture = try fixture(), value = controller(fixture)
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        let worker = try identity(fixture)
        let resource = try XCTUnwrap(try session(fixture)["resource"] as? String)
        let resourcePath = try XCTUnwrap(URL(string: resource)?.path)
        value.mountSnapshotForTesting = { [MountEntry(path: value.mountpoint.path, source: resourcePath, type: "clouddrive", id: "owned-fixture")] }
        try await value.refreshForTesting()
        XCTAssertTrue(value.mounted)
        value.mountSnapshotForTesting = { [] }
        try await value.refreshForTesting()
        XCTAssertFalse(value.mounted)
        try await awaitRetirement(value)
        XCTAssertFalse(value.hasSession, value.error); XCTAssertTrue(worker.hasExited)
        try FileManager.default.removeItem(at: fixture.root)
    }
    func testFinderMultiselectionResolvesAllItemsAndRechecksMountBeforeCacheMutations() async throws {
        let fixture = try fixture(); try await seed(fixture)
        let remote = try FixtureStorageRemote(directory: fixture.remoteDirectory)
        _ = try await remote.put(key: "fixture/Other.txt", data: Data("second fixture".utf8), condition: .absent, operationID: UUID())
        let value = controller(fixture)
        await value.prepare(connection: fixture.connection, mode: .compatible, legacySafe: true)
        await value.importMetadata(); await value.enableWrites()
        XCTAssertTrue(value.enabled, value.error); XCTAssertFalse(value.readOnly)
        let saved = try session(fixture), resource = try XCTUnwrap(URL(string: try XCTUnwrap(saved["resource"] as? String)))
        let ownedMount = MountEntry(path: value.mountpoint.path, source: resource.path, type: "clouddrive", id: "fixture-owned")
        value.mountSnapshotForTesting = { [ownedMount] }; try await value.refreshForTesting()
        let client = try rpc(fixture)
        func pins() async throws -> [PinProgress] {
            let response = try await client.call(.init(operation: "pinStatus"))
            return try JSONDecoder().decode([PinProgress].self, from: XCTUnwrap(response.data))
        }
        let first = value.mountpoint.appendingPathComponent("Folder/file.txt").path
        let second = value.mountpoint.appendingPathComponent("Other.txt").path
        await value.handleFinderAction(try .init(action: .keepDownloaded, paths: [first, value.mountpoint.appendingPathComponent("Missing.txt").path]))
        XCTAssertFalse(value.error.isEmpty)
        let afterMissing = try await pins(); XCTAssertTrue(afterMissing.isEmpty, "No earlier selection may be pinned if a later lookup fails")

        var mountReads = 0
        value.mountSnapshotForTesting = {
            mountReads += 1
            return mountReads == 1 ? [ownedMount] : [MountEntry(path: value.mountpoint.path, source: "/foreign", type: "clouddrive", id: "foreign")]
        }
        await value.handleFinderAction(try .init(action: .keepDownloaded, paths: [first, second]))
        XCTAssertGreaterThanOrEqual(mountReads, 2); XCTAssertFalse(value.error.isEmpty)
        let afterReplacement = try await pins(); XCTAssertTrue(afterReplacement.isEmpty)

        value.mountSnapshotForTesting = { [ownedMount] }
        await value.handleFinderAction(try .init(action: .keepDownloaded, paths: [first, second]))
        XCTAssertTrue(value.error.isEmpty, value.error)
        let pinned = try await pins(); XCTAssertEqual(pinned.count, 2)
        await value.handleFinderAction(try .init(action: .freeSpace, paths: [first, second]))
        XCTAssertTrue(value.error.isEmpty, value.error)
        let unpinned = try await pins(); XCTAssertTrue(unpinned.isEmpty)
        await cleanup(value, fixture: fixture)
        XCTAssertFalse(value.hasSession, value.error)
    }
    private func publishManagedFixture(_ fixture: Fixture) async throws -> (volumeID: UUID, rootID: UUID, fileID: UUID, inode: Int64) {
        try await seed(fixture)
        let remote = try FixtureStorageRemote(directory: fixture.remoteDirectory)
        let volume = UUID(), root = UUID(), folder = UUID(), file = UUID()
        let object = try await remote.head(key: "fixture/Folder/file.txt")
        let source = try XCTUnwrap(object)
        let records = [
            NamespaceNode(id: root, inode: 2, parentID: nil, name: "", kind: .directory),
            NamespaceNode(id: folder, inode: 21, parentID: root, name: "Folder", kind: .directory),
            NamespaceNode(id: file, inode: 20, parentID: folder, name: "file.txt", kind: .file, size: source.size, contentGeneration: 7,
                          backing: .init(key: source.key, validator: source.validator, size: source.size, checksum: source.checksum))
        ]
        let publisher = ManagedManifestPublisher(remote: remote, prefix: "fixture", volumeID: volume)
        let publication = try await publisher.prepare(revision: 7, operationIDs: [], updates: records.map { ManagedNodeRecord(node: $0) })
        try await publisher.publish(publication, operationID: UUID())
        return (volume, root, file, 20)
    }
    private func rpc(_ fixture: Fixture) throws -> UnixSocketRPCClient {
        let saved = try session(fixture), source = try XCTUnwrap(saved["resource"] as? String), url = try XCTUnwrap(URL(string: source))
        return UnixSocketRPCClient(descriptor: try NamespaceOwnerDescriptor.read(from: url.appendingPathComponent(".clouddrive-owner.json")))
    }
    func testManagedRecoveryUsesFreshStorePreservesEarlierPendingRecordsAndNativeIDs() async throws {
        let fixture = try fixture(), expected = try await publishManagedFixture(fixture)
        let originalDirectory = fixture.root.appendingPathComponent("Namespaces/" + fixture.connection.fingerprint + "/Namespace")
        let old = try NamespaceStore(directory: originalDirectory, binding: fixture.connection.fingerprint)
        let oldRoot = try await old.volume().rootID
        _ = try await old.create(parentID: oldRoot, name: "locally-pending", kind: .file)
        await old.close()
        let original = originalDirectory.appendingPathComponent("namespace.sqlite"), bytes = try Data(contentsOf: original)
        let value = controller(fixture)
        await value.prepareManagedRecovery(connection: fixture.connection, legacySafe: true)
        XCTAssertTrue(value.running, value.error); XCTAssertTrue(value.readOnly); XCTAssertTrue(value.enabled)
        guard value.running else { print("NAMESPACE_FIXTURE_DIAGNOSTICS " + fixture.root.path); return }
        XCTAssertEqual(value.importProgress?.volumeID, expected.volumeID)
        XCTAssertEqual(value.importProgress?.complete, true)
        let selected = try XCTUnwrap(try session(fixture)["storageDirectory"] as? String)
        XCTAssertTrue(selected.contains("/Recovered/"))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let reply = try await rpc(fixture).call(.init(operation: "node", nodeID: expected.fileID))
        XCTAssertEqual(reply.node?.id, expected.fileID); XCTAssertEqual(reply.node?.inode, expected.inode)
        XCTAssertEqual(reply.node?.contentGeneration, 7)
        await value.eject(); try await awaitRetirement(value)
        XCTAssertFalse(value.hasSession, value.error)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let reopened = controller(fixture)
        XCTAssertTrue(reopened.enabled); XCTAssertTrue(reopened.readOnly)
        await reopened.recover()
        XCTAssertTrue(reopened.running, reopened.error); XCTAssertTrue(reopened.readOnly, "Recovery selection must not enable writes after restart")
        await reopened.eject(); try await awaitRetirement(reopened)
        if !reopened.hasSession { try FileManager.default.removeItem(at: fixture.root) }
    }
    func testRecoveredManagedDriveExportsWithoutDeletingAndReopensSelectedStore() async throws {
        let fixture = try fixture(), expected = try await publishManagedFixture(fixture), value = controller(fixture)
        await value.prepareManagedRecovery(connection: fixture.connection, legacySafe: true)
        XCTAssertTrue(value.running, value.error)
        guard value.running else { print("NAMESPACE_FIXTURE_DIAGNOSTICS " + fixture.root.path); return }
        let remote = try FixtureStorageRemote(directory: fixture.remoteDirectory)
        let before = try await remote.head(key: "fixture/.clouddrive/v1/HEAD")
        await value.exportFiles(toPrefix: "fixture/Exported")
        XCTAssertTrue(value.error.isEmpty, value.error)
        let copied = try await remote.head(key: "fixture/Exported/Folder/file.txt"), original = try await remote.head(key: "fixture/Folder/file.txt")
        XCTAssertEqual(copied?.size, original?.size); XCTAssertNotNil(copied); XCTAssertNotNil(original)
        await value.enableWrites()
        XCTAssertTrue(value.enabled, value.error); XCTAssertFalse(value.readOnly)
        let after = try await remote.head(key: "fixture/.clouddrive/v1/HEAD")
        XCTAssertEqual(before?.validator, after?.validator, "Enabling a recovered drive must not seed a second namespace")
        let selected = try session(fixture)["storageDirectory"] as? String
        await value.eject(); try await awaitRetirement(value); XCTAssertFalse(value.hasSession, value.error)
        let reopened = controller(fixture)
        XCTAssertTrue(reopened.enabled)
        await reopened.recover()
        XCTAssertTrue(reopened.running, reopened.error)
        XCTAssertEqual(try session(fixture)["storageDirectory"] as? String, selected)
        let reply = try await rpc(fixture).call(.init(operation: "node", nodeID: expected.fileID))
        XCTAssertEqual(reply.node?.inode, expected.inode)
        await reopened.eject(); try await awaitRetirement(reopened); XCTAssertFalse(reopened.hasSession, reopened.error)
        if !reopened.hasSession { try FileManager.default.removeItem(at: fixture.root) }
    }
    func testCapabilityCannotRedirectOwnerIntoForeignOrSymlinkedStore() async throws {
        let fixture = try fixture(), base = fixture.root.appendingPathComponent("Namespaces/" + fixture.connection.fingerprint)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outside = fixture.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let selected = base.appendingPathComponent("Redirected")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        let capability: [String: Any] = ["version": 1, "binding": fixture.connection.fingerprint, "mode": "managed", "storageDirectory": selected.absoluteString, "recoveredManaged": true]
        let file = base.appendingPathComponent("capability.json")
        try JSONSerialization.data(withJSONObject: capability).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let value = controller(fixture)
        XCTAssertTrue(value.capabilityBlocked); await value.recover()
        XCTAssertFalse(value.running); XCTAssertFalse(value.hasSession)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testMountOwnershipRequiresExactResourceTypeAndPersistedIdentity() throws {
        let resource = URL(fileURLWithPath: "/tmp/clouddrive-fixture/resource"), mount = URL(fileURLWithPath: "/tmp/fixture-mount")
        let valid = MountEntry(path: mount.path, source: resource.path, type: "clouddrive", id: "1:2")
        XCTAssertNoThrow(try NamespaceDriveController.validateMount(valid, resource: resource, mountpoint: mount, expectedID: "1:2"))
        var spoof = valid; spoof.source += "-another"
        XCTAssertThrowsError(try NamespaceDriveController.validateMount(spoof, resource: resource, mountpoint: mount, expectedID: "1:2"))
        var foreign = valid; foreign.type = "nfs"
        XCTAssertThrowsError(try NamespaceDriveController.validateMount(foreign, resource: resource, mountpoint: mount, expectedID: "1:2"))
        XCTAssertThrowsError(try NamespaceDriveController.validateMount(valid, resource: resource, mountpoint: mount, expectedID: "new-mount"))
        var fileURL = valid; fileURL.source = resource.absoluteString
        XCTAssertNoThrow(try NamespaceDriveController.validateMount(fileURL, resource: resource, mountpoint: mount, expectedID: "1:2"))
    }
}
