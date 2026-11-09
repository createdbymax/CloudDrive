import XCTest
import Foundation
import Darwin
@testable import CloudDriveCore

private actor PeerObservations {
    var peers: [NamespaceRPCPeer] = []
    func add(_ peer: NamespaceRPCPeer) { peers.append(peer) }
    func count() -> Int { peers.count }
}

private actor BlockedReadStorage: StorageRemote {
    private let base: FixtureStorageRemote
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(_ base: FixtureStorageRemote) { self.base = base }
    func head(key: String) async throws -> StorageObject? { try await base.head(key: key) }
    func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange {
        started = true
        await withCheckedContinuation { waiter = $0 }
        return try await base.read(key: key, range: range, validator: validator)
    }
    func hasStarted() -> Bool { started }
    func release() { waiter?.resume(); waiter = nil }
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject { try await base.put(key: key, data: data, condition: condition, operationID: operationID) }
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) async throws -> StorageObject { try await base.copy(source: source, destination: destination, sourceValidator: sourceValidator, operationID: operationID) }
    func delete(key: String, validator: String) async throws { try await base.delete(key: key, validator: validator) }
    func list(prefix: String, cursor: String?, limit: Int) async throws -> StoragePage { try await base.list(prefix: prefix, cursor: cursor, limit: limit) }
}

private actor PausedRPCReads {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    func started() -> Int { count }
    func release() { let pending = waiting; waiting.removeAll(); for value in pending { value.resume() } }
    func reply(_ request: NamespaceRPCRequest) async -> NamespaceRPCResponse {
        if request.operation == "read" { count += 1; await withCheckedContinuation { waiting.append($0) } }
        var response = NamespaceRPCResponse(requestID: request.requestID)
        response.attributes = ["ready": "true"]; response.data = Data([0x41]); return response
    }
}

private actor BusyRPCReplies {
    private var requests: [UUID] = []
    func observed() -> [UUID] { requests }
    func reply(_ request: NamespaceRPCRequest) -> NamespaceRPCResponse {
        requests.append(request.requestID)
        if requests.count < 3 { return NamespaceRPCResponse.failure(request, error: POSIXError(.EBUSY)) }
        var response = NamespaceRPCResponse(requestID: request.requestID); response.attributes = ["ready": "true"]; return response
    }
}

final class NamespaceOwnerTests: XCTestCase {
    // Plain values let async actor calls finish before XCTest's autoclosures.
    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(actual, expected, message, file: file, line: line) }
    private func assertTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, message, file: file, line: line) }
    private func assertFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, message, file: file, line: line) }
    private func required<T>(_ value: T?) throws -> T { guard let value else { throw POSIXError(.ENOENT) }; return value }
    private struct Fixture {
        let directory: URL
        let remote: FixtureStorageRemote
        let store: NamespaceStore
        let content: ContentStore
        let cache: RangeCache
        let sync: SyncEngine
        let owner: NamespaceOwner
        let rootID: UUID
        let source: NamespaceNode
        let target: NamespaceNode
        let child: NamespaceNode
    }
    private func directory() throws -> URL {
        let parent = URL(fileURLWithPath: "/tmp/clouddrive-owner-tests-"+String(getuid())).resolvingSymlinksInPath()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
        let child = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return child
    }
    private func fixture(readOnly: Bool = false) async throws -> Fixture {
        let root = try directory(), remote = try FixtureStorageRemote(directory: root.appendingPathComponent("Remote"))
        let object = try await remote.put(key: "fixture/Before/child.bin", data: Data("payload".utf8), condition: .absent, operationID: UUID())
        let store = try NamespaceStore(directory: root.appendingPathComponent("Namespace"), binding: "synthetic")
        try await store.importEntries([.init(path: "Before/child.bin", size: 7, backing: .init(key: object.key, validator: object.validator, size: object.size, checksum: object.checksum)), .init(path: "Target", kind: .directory)])
        let volume = try await store.volume()
        let source = try required(try await store.lookup(parentID: volume.rootID, name: "Before"))
        let target = try required(try await store.lookup(parentID: volume.rootID, name: "Target"))
        let child = try required(try await store.lookup(parentID: source.id, name: "child.bin"))
        let content = try ContentStore(directory: root.appendingPathComponent("Content"), maximumBytes: 1024*1024)
        let cache = try RangeCache(directory: root.appendingPathComponent("Cache"), maximumBytes: 8192, chunkSize: 4096)
        let sync = SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: "fixture")
        let owner = NamespaceOwner(store: store, sync: sync, directory: root, readOnly: readOnly)
        return Fixture(directory: root, remote: remote, store: store, content: content, cache: cache, sync: sync, owner: owner, rootID: volume.rootID, source: source, target: target, child: child)
    }
    private func childProcess() throws -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); return process
    }
    private func stop(_ process: Process) async throws {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !process.isRunning else { kill(process.processIdentifier, SIGKILL); throw POSIXError(.ETIMEDOUT) }
    }
    private func request(_ operation: String, node: UUID? = nil, handle: UUID? = nil, peer: NamespaceRPCPeer? = nil) -> NamespaceRPCRequest {
        var request = NamespaceRPCRequest(operation: operation, nodeID: node, handleID: handle); request.trustedPeer = peer; return request
    }
    private func successful(_ response: NamespaceRPCResponse, file: StaticString = #filePath, line: UInt = #line) throws -> NamespaceRPCResponse {
        if let error = response.error { XCTFail("Unexpected retained-operation error: \(error.errno)", file: file, line: line); throw POSIXError(.EIO) }
        return response
    }
    func testAvailabilityRPCVerifiesCurrentCacheAndNeverClaimsDirtyContentOffline() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        func availability() async throws -> String? {
            try successful(await f.owner.handle(.init(operation: "availability", nodeID: f.child.id))).attributes?["availability"]
        }
        assertEqual(try await availability(), "remoteOnly")
        let n = f.child
        let stale = NamespaceNode(id: n.id, inode: n.inode, parentID: n.parentID, name: n.name, kind: n.kind, size: n.size,
                                  contentGeneration: n.contentGeneration + 1, metadataGeneration: n.metadataGeneration,
                                  modifiedAt: n.modifiedAt, deletedRevision: nil, backing: n.backing, stagedSnapshotID: nil)
        try await f.cache.requestPin(node: stale)
        try await f.cache.updatePin(nodeID: n.id, completedBytes: n.size, state: "complete")
        assertEqual(try await availability(), "unknown")
        try await f.cache.requestPin(node: n)
        assertEqual(try await availability(), "downloading")
        _ = try await f.sync.read(nodeID: n.id, offset: 0, length: Int(n.size))
        try await f.cache.updatePin(nodeID: n.id, completedBytes: n.size, state: "complete")
        assertEqual(try await availability(), "availableOffline")
        try await f.cache.unpin(nodeID: n.id)
        _ = try await f.sync.write(nodeID: n.id, offset: 0, data: Data("dirty".utf8))
        assertEqual(try await availability(), "unknown")
        let missing = await f.owner.handle(.init(operation: "availability", nodeID: UUID()))
        XCTAssertNotNil(missing.error)
        await f.store.close()
    }
    func testRenameReplayIsDurableAndDifferentArgumentsCannotReuseRequestIdentity() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let rename = NamespaceRPCRequest(operation: "rename", nodeID: f.source.id, destinationParentID: f.target.id, destinationName: "After")
        let first = try successful(await f.owner.handle(rename)), replay = try successful(await f.owner.handle(rename))
        assertEqual(first.node, replay.node)
        let revision = try await f.store.volume().revision
        var conflicting = rename; conflicting.destinationName = "Different"
        assertEqual((await f.owner.handle(conflicting)).error?.errno, EPROTO)
        assertEqual(try await f.store.resolvedPath(f.child.id), "Target/After/child.bin")
        await f.store.close()
        let reopened = try NamespaceStore(directory: f.directory.appendingPathComponent("Namespace"), binding: "synthetic")
        let sync = SyncEngine(store: reopened, content: f.content, cache: f.cache, remote: f.remote, prefix: "fixture")
        let owner = NamespaceOwner(store: reopened, sync: sync, directory: f.directory, readOnly: false)
        let recovered = try successful(await owner.handle(rename))
        assertEqual(recovered.node?.id, f.source.id)
        assertEqual(try await reopened.volume().revision, revision)
        assertEqual((await owner.handle(conflicting)).error?.errno, EPROTO)
        await reopened.close()
    }
    func testReadonlyAndQuiescingAdmissionProtectFutureWritesAndReaders() async throws {
        let f = try await fixture(readOnly: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        let create = NamespaceRPCRequest(operation: "create", parentID: f.rootID, name: "new", kind: .file)
        assertEqual((await f.owner.handle(create)).error?.errno, EROFS)
        _ = try successful(await f.owner.handle(request("attach")))
        assertEqual((await f.owner.handle(request("enableWrites"))).error?.errno, EBUSY)
        _ = try successful(await f.owner.handle(request("detach")))
        _ = try successful(await f.owner.handle(request("enableWrites")))
        _ = try successful(await f.owner.handle(request("prepareStop")))
        for operation in ["open", "read", "resume", "attach"] {
            let result = await f.owner.handle(request(operation, node: f.child.id))
            assertEqual(result.error?.errno, EBUSY, operation)
        }
        var freshCreate = create; freshCreate.requestID = UUID()
        assertEqual((await f.owner.handle(freshCreate)).error?.errno, EBUSY)
        let status = try successful(await f.owner.handle(request("status")))
        assertEqual(status.attributes?["quiescing"], "true")
    }
    func testLeasesAndCachedResponsesCannotBeUsedByAnotherLiveClient() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try childProcess(), second = try childProcess()
        defer { if first.isRunning { first.terminate() }; if second.isRunning { second.terminate() } }
        let a = try NamespaceRPCPeer.capture(pid: first.processIdentifier), b = try NamespaceRPCPeer.capture(pid: second.processIdentifier)
        let open = request("open", node: f.child.id, peer: a)
        let opened = try successful(await f.owner.handle(open)), handle = try XCTUnwrap(opened.handleID)
        var stolenReplay = open; stolenReplay.trustedPeer = b
        let rejected = await f.owner.handle(stolenReplay)
        assertEqual(rejected.error?.errno, EPROTO); XCTAssertNil(rejected.handleID)
        for operation in ["node", "read", "write", "close"] {
            var stolen = request(operation, node: f.child.id, handle: handle, peer: b)
            stolen.offset = 0; stolen.length = 7; stolen.data = Data("changed".utf8)
            assertEqual((await f.owner.handle(stolen)).error?.errno, EBADF, operation)
        }
        var read = request("read", node: f.child.id, handle: handle, peer: a); read.offset = 0; read.length = 7
        assertEqual(try successful(await f.owner.handle(read)).data, Data("payload".utf8))
        await f.owner.reapExitedClients()
        assertFalse(await f.owner.canStop(), "Healthy client has no timeout-based eviction")
        _ = try successful(await f.owner.handle(request("close", node: f.child.id, handle: handle, peer: a)))
        assertTrue(await f.owner.canStop())
        try await stop(first); try await stop(second)
    }
    func testExitedClientLeasesAreReapedWhilePausedWithoutTouchingNamespace() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let child = try childProcess(); defer { if child.isRunning { child.terminate() } }
        let peer = try NamespaceRPCPeer.capture(pid: child.processIdentifier)
        let opened = try successful(await f.owner.handle(request("open", node: f.child.id, peer: peer)))
        XCTAssertNotNil(opened.handleID)
        _ = try successful(await f.owner.handle(request("pause")))
        let before = try await f.store.volume().revision
        await f.owner.backgroundStep()
        assertFalse(await f.owner.canStop())
        try await stop(child)
        assertTrue(peer.hasDefinitelyExited)
        await f.owner.backgroundStep()
        let status = try successful(await f.owner.handle(request("status")))
        assertEqual(status.attributes?["openHandles"], "0"); assertEqual(status.attributes?["paused"], "true")
        assertEqual(try await f.store.volume().revision, before)
        assertTrue(await f.owner.canStop())
    }
    func testPIDIncarnationAndUntrustedJSONCannotForgePeerIdentity() throws {
        let current = try NamespaceRPCPeer.capture(pid: getpid())
        assertTrue(current.matchesRunningProcess); assertFalse(current.hasDefinitelyExited)
        let previous = NamespaceRPCPeer(pid: current.pid, uid: current.uid, startSeconds: current.startSeconds - 1, startMicroseconds: current.startMicroseconds)
        assertFalse(previous.matchesRunningProcess); assertTrue(previous.hasDefinitelyExited)
        var request = NamespaceRPCRequest(operation: "status"); request.trustedPeer = current
        let encoded = try JSONEncoder().encode(request)
        assertFalse(String(decoding: encoded, as: UTF8.self).contains("trustedPeer"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["trustedPeer"] = ["pid": 1, "uid": 0, "startSeconds": 1, "startMicroseconds": 1]
        let decoded = try JSONDecoder().decode(NamespaceRPCRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.trustedPeer)
    }
    func testPrivateDescriptorRejectsSymlinksHardlinksPermissionsAndMalformedShape() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("owner.sock").path, token: String(repeating: "a", count: 64), binding: "synthetic")
        try descriptor.save(in: root)
        let file = root.appendingPathComponent(".clouddrive-owner.json")
        assertEqual(try NamespaceOwnerDescriptor.read(from: file).sessionID, descriptor.sessionID)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try NamespaceOwnerDescriptor.read(from: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let symlink = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        XCTAssertThrowsError(try NamespaceOwnerDescriptor.read(from: symlink))
        let hardlink = root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: file, to: hardlink)
        XCTAssertThrowsError(try NamespaceOwnerDescriptor.read(from: file))
        try FileManager.default.removeItem(at: hardlink)
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]); invalid["protocolVersion"] = 2
        try JSONSerialization.data(withJSONObject: invalid).write(to: file)
        XCTAssertThrowsError(try NamespaceOwnerDescriptor.read(from: file))
    }
    func testSocketInjectsKernelPeerAndStopsWithoutWaitingForIdleTimeout() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("owner.sock").path, token: String(repeating: "b", count: 64), binding: "synthetic")
        let observations = PeerObservations()
        let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: false) { request in
            if let peer = request.trustedPeer { await observations.add(peer) }
            var response = NamespaceRPCResponse(requestID: request.requestID)
            response.attributes = ["pid": String(request.trustedPeer?.pid ?? 0)]; return response
        }
        let run = Task.detached { try server.run() }
        let client = UnixSocketRPCClient(descriptor: descriptor), deadline = Date().addingTimeInterval(3)
        var response: NamespaceRPCResponse?
        while response == nil, Date() < deadline {
            response = try? await client.call(NamespaceRPCRequest(operation: "status"))
            if response == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard let response else { server.stop(); _ = try? await run.value; throw POSIXError(.ETIMEDOUT) }
        assertEqual(response.attributes?["pid"], String(getpid()))
        let count = await observations.count(); assertEqual(count, 1)
        let before = ContinuousClock.now
        server.stop(); try await run.value
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        assertFalse(FileManager.default.fileExists(atPath: descriptor.socketPath))
    }
    func testDeadClientLeaseWaitsForAcceptedReadToFinishBeforeReaping() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let blocked = BlockedReadStorage(f.remote)
        let sync = SyncEngine(store: f.store, content: f.content, cache: f.cache, remote: blocked, prefix: "fixture")
        let owner = NamespaceOwner(store: f.store, sync: sync, directory: f.directory, readOnly: false)
        let process = try childProcess(); defer { if process.isRunning { process.terminate() } }
        let peer = try NamespaceRPCPeer.capture(pid: process.processIdentifier)
        let opened = try successful(await owner.handle(request("open", node: f.child.id, peer: peer)))
        let handle = try XCTUnwrap(opened.handleID)
        var read = request("read", node: f.child.id, handle: handle, peer: peer); read.offset = 0; read.length = 7
        let readTask = Task { await owner.handle(read) }
        let deadline = Date().addingTimeInterval(2)
        while !(await blocked.hasStarted()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard await blocked.hasStarted() else { await blocked.release(); throw POSIXError(.ETIMEDOUT) }
        try await stop(process)
        await owner.reapExitedClients()
        let held = try successful(await owner.handle(request("status")))
        assertEqual(held.attributes?["openHandles"], "1")
        await blocked.release()
        assertEqual(try successful(await readTask.value).data, Data("payload".utf8))
        await owner.reapExitedClients()
        let finished = try successful(await owner.handle(request("status")))
        assertEqual(finished.attributes?["openHandles"], "0")
        assertTrue(await owner.canStop())
    }
    func testMalformedSetAttributesCannotAcknowledgeOrChangeNamespace() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try await f.store.volume().revision
        for values in [["size": "not-an-integer"], ["size": "-1"], ["modifiedAt": "not-a-date"]] {
            let request = NamespaceRPCRequest(operation: "setattrs", nodeID: f.child.id, attributes: values)
            assertEqual((await f.owner.handle(request)).error?.errno, EINVAL)
        }
        assertEqual(try await f.store.volume().revision, before)
        assertEqual(try await f.store.node(f.child.id).size, 7)
    }

    func testRawWriteFramePreservesEveryByteAndLegacyDescriptorUsesJSON() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("owner.sock").path,
            token: String(repeating: "d", count: 64), binding: "synthetic")
        let chunk = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        let bytes = (0..<100).reduce(into: Data()) { data, _ in data.append(chunk) }
        let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: false) { request in
            var result = NamespaceRPCResponse(requestID: request.requestID)
            result.attributes = ["exact": String(request.data == bytes || request.data == chunk)]
            return result
        }
        let run = Task.detached { try server.run() }; defer { server.stop() }
        let end = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: descriptor.socketPath), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        let response = try await UnixSocketRPCClient(descriptor: descriptor).call(.init(operation: "write", offset: 0, data: bytes))
        XCTAssertEqual(response.attributes?["exact"], "true")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
        old.removeValue(forKey: "rawWriteLimit")
        let legacy = try JSONDecoder().decode(NamespaceOwnerDescriptor.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.rawWriteLimit)
        let ordinary = try await UnixSocketRPCClient(descriptor: legacy).call(.init(operation: "write", offset: 0, data: chunk))
        XCTAssertEqual(ordinary.attributes?["exact"], "true")
        server.stop(); try await run.value
    }

    func testWrongTokenNeverReachesHandlerAndMalformedServerCapabilityIsRejected() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("owner.sock").path, token: String(repeating: "c", count: 64), binding: "synthetic")
        let observations = PeerObservations()
        let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: false) { request in
            if let peer = request.trustedPeer { await observations.add(peer) }
            return NamespaceRPCResponse(requestID: request.requestID)
        }
        let run = Task.detached { try server.run() }, deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: descriptor.socketPath), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let invalid = NamespaceOwnerDescriptor(socketPath: descriptor.socketPath, token: String(repeating: "d", count: 64), binding: "synthetic")
        do { _ = try await UnixSocketRPCClient(descriptor: invalid).call(NamespaceRPCRequest(operation: "status")); XCTFail("Wrong token must not authenticate") }
        catch { /* The unauthenticated connection receives no reflected private details. */ }
        assertEqual(await observations.count(), 0)
        server.stop(); try await run.value
        let malformed = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("invalid.sock").path, token: "", binding: "synthetic")
        let rejected = UnixSocketRPCServer(descriptor: malformed, requireSignedPeers: false) { NamespaceRPCResponse(requestID: $0.requestID) }
        XCTAssertThrowsError(try rejected.run())
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformed.socketPath))
    }

    func testRealSocketClientProcessCannotTransferItsLeaseToAnotherProcess() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: f.directory.appendingPathComponent("owner.sock").path, token: String(repeating: "e", count: 64), binding: "synthetic")
        let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: false) { await f.owner.handle($0) }
        let run = Task.detached { try server.run() }; defer { server.stop() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: descriptor.socketPath), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let resultFile = f.directory.appendingPathComponent("client-result.json")
        let program = """
        import json,pathlib,socket,struct,sys,time,uuid
        value=json.load(sys.stdin)
        request={'protocolVersion':1,'requestID':str(uuid.uuid4()),'authToken':value['token'],'operation':'open','nodeID':value['nodeID']}
        connection=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);connection.settimeout(2);connection.connect(value['socketPath'])
        body=json.dumps(request).encode();connection.sendall(struct.pack('!I',len(body))+body)
        def read_exact(length):
            data=b''
            while len(data)<length:
                chunk=connection.recv(length-len(data))
                if not chunk:raise RuntimeError('truncated response')
                data+=chunk
            return data
        length=struct.unpack('!I',read_exact(4))[0]
        if length>4194304:raise RuntimeError('oversized response')
        result=read_exact(length);connection.close();pathlib.Path(value['result']).write_bytes(result)
        time.sleep(30)
        """
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = ["-c", program]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["socketPath": descriptor.socketPath,"token": descriptor.token,"nodeID": f.child.id.uuidString,"result": resultFile.path]))
        try input.fileHandleForWriting.close()
        while !FileManager.default.fileExists(atPath: resultFile.path), process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard FileManager.default.fileExists(atPath: resultFile.path) else { throw POSIXError(.ETIMEDOUT) }
        let opened = try JSONDecoder().decode(NamespaceRPCResponse.self, from: Data(contentsOf: resultFile))
        let handle = try XCTUnwrap(try successful(opened).handleID)
        let client = UnixSocketRPCClient(descriptor: descriptor)
        do { _ = try await client.call(request("close", node: f.child.id, handle: handle)); XCTFail("Different process cannot close this lease") }
        catch { assertEqual((error as NSError).code, Int(EBADF)) }
        let held = try await client.call(request("status")); assertEqual(held.attributes?["openHandles"], "1")
        try await stop(process)
        let reaped = try await client.call(request("status")); assertEqual(reaped.attributes?["openHandles"], "0")
        assertTrue(await f.owner.canStop())
        server.stop(); try await run.value
    }

    func testTypedFailuresPreserveUsefulCodesWithoutEchoingPrivateErrors() {
        let request = NamespaceRPCRequest(operation: "status")
        let cases: [(Error, Int32, String)] = [(StorageFailure.unsupported, ENOTSUP, "storage.unsupported"), (StorageFailure.localStorageFull, ENOSPC, "storage.localStorageFull"), (StorageFailure.conflict, ESTALE, "storage.conflict"), (NamespaceFailure.generationChanged, ESTALE, "namespace.generationChanged"), (NamespaceFailure.invalidTransition, EINVAL, "namespace.invalidTransition")]
        for (error, code, kind) in cases {
            let response = NamespaceRPCResponse.failure(request, error: error)
            assertEqual(response.error?.errno, code); assertEqual(response.attributes?["failureKind"], kind)
        }
        let privateError = NSError(domain: "provider", code: 999, userInfo: [NSLocalizedDescriptionKey: "secret-token private/path provider raw response"])
        let redacted = NamespaceRPCResponse.failure(request, error: privateError)
        assertEqual(redacted.attributes?["failureKind"], "internal.unclassified")
        assertFalse(redacted.error?.message.contains("secret-token") == true)
        assertFalse(redacted.error?.message.contains("private/path") == true)
    }

    func testTransientBusyIsNotCachedAfterAdmissionConditionsChange() async throws {
        let f = try await fixture(readOnly: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try successful(await f.owner.handle(request("attach")))
        let enable = request("enableWrites")
        assertEqual((await f.owner.handle(enable)).error?.errno, EBUSY)
        _ = try successful(await f.owner.handle(request("detach")))
        let accepted = try successful(await f.owner.handle(enable))
        assertEqual(accepted.attributes?["readOnly"], "false")
    }
    func testBusyRetryRetainsExactRequestIdentityAndFinishesWithinBound() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("owner.sock").path, token: String(repeating: "f", count: 64), binding: "synthetic")
        let replies = BusyRPCReplies()
        let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: false) { await replies.reply($0) }
        let run = Task.detached { try server.run() }; defer { server.stop() }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: descriptor.socketPath), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let value = request("status"), started = ContinuousClock.now
        let response = try await UnixSocketRPCClient(descriptor: descriptor).call(value)
        assertEqual(response.attributes?["ready"], "true")
        let ids = await replies.observed(); assertEqual(ids, [value.requestID, value.requestID, value.requestID])
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        server.stop(); try await run.value
    }
    func testPausedContentReadsKeepReservedMetadataResponsiveAndRejectExcessIOWithTypedBusy() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("owner.sock").path, token: String(repeating: "1", count: 64), binding: "synthetic")
        let paused = PausedRPCReads()
        let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: false) { await paused.reply($0) }
        let run = Task.detached { try server.run() }; defer { server.stop() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: descriptor.socketPath), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let client = UnixSocketRPCClient(descriptor: descriptor)
        let readers = (0..<16).map { _ in Task { try await client.call(NamespaceRPCRequest(operation: "read", nodeID: UUID(), offset: 0, length: 1)) } }
        while await paused.started() < 16, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard await paused.started() == 16 else { await paused.release(); for task in readers { _ = try? await task.value }; throw POSIXError(.ETIMEDOUT) }
        let start = ContinuousClock.now
        let status = try await client.call(request("status"))
        assertEqual(status.attributes?["ready"], "true")
        let metadataTime = start.duration(to: .now)
        XCTAssertLessThan(metadataTime, .seconds(1))
        print("IPC_BACKPRESSURE paused_reads=16 metadata_seconds=\(metadataTime)")
        let excess = NamespaceRPCRequest(operation: "read", nodeID: UUID(), offset: 0, length: 1)
        do { _ = try await client.call(excess); XCTFail("Client I/O admission must remain bounded") }
        catch {
            let failure = error as NSError
            assertEqual(failure.code, Int(EBUSY)); assertEqual(failure.userInfo["failureKind"] as? String, "transport.busy")
            assertEqual(failure.userInfo["requestID"] as? String, excess.requestID.uuidString)
        }
        // A second process bypasses this process's client lanes, exercising the
        // server's authenticated I/O lane rejection rather than connection reset.
        let output = root.appendingPathComponent("server-busy.json"), input = Pipe(), process = Process()
        let program = """
        import json,pathlib,socket,struct,sys,uuid
        value=json.load(sys.stdin);request={'protocolVersion':1,'requestID':value['requestID'],'authToken':value['token'],'operation':'read','offset':0,'length':1}
        connection=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);connection.settimeout(2);connection.connect(value['socketPath'])
        body=json.dumps(request).encode();connection.sendall(struct.pack('!I',len(body))+body)
        def exact(length):
            data=b''
            while len(data)<length:
                chunk=connection.recv(length-len(data))
                if not chunk:raise RuntimeError('reset instead of typed busy')
                data+=chunk
            return data
        length=struct.unpack('!I',exact(4))[0]
        if length>4194304:raise RuntimeError('oversized frame')
        pathlib.Path(value['output']).write_bytes(exact(length))
        """
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = ["-c", program]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate() } }
        let rawID = UUID()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["requestID": rawID.uuidString,"token": descriptor.token,"socketPath": descriptor.socketPath,"output": output.path])); try input.fileHandleForWriting.close()
        let replyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: output.path), process.isRunning, Date() < replyDeadline { try await Task.sleep(for: .milliseconds(5)) }
        if FileManager.default.fileExists(atPath: output.path) {
            let busy = try JSONDecoder().decode(NamespaceRPCResponse.self, from: Data(contentsOf: output))
            assertEqual(busy.requestID, rawID); assertEqual(busy.error?.errno, EBUSY); assertEqual(busy.attributes?["failureKind"], "transport.busy")
        } else { XCTFail("Server should return an authenticated busy frame without accepting extra content work") }
        assertEqual(await paused.started(), 16)
        await paused.release()
        for task in readers { assertEqual(try await task.value.data, Data([0x41])) }
        server.stop(); try await run.value
    }
    func testCancellingSocketReadReleasesClientLaneWithoutCancellingAcceptedOwnerWork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = NamespaceOwnerDescriptor(socketPath: root.appendingPathComponent("owner.sock").path, token: String(repeating: "2", count: 64), binding: "synthetic")
        let paused = PausedRPCReads()
        let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: false) { await paused.reply($0) }
        let run = Task.detached { try server.run() }; defer { server.stop() }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: descriptor.socketPath), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let task = Task { try await UnixSocketRPCClient(descriptor: descriptor).call(NamespaceRPCRequest(operation: "read", offset: 0, length: 1)) }
        while await paused.started() < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let started = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled client must return promptly") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        assertEqual(await paused.started(), 1)
        await paused.release()
        server.stop(); try await run.value
    }

    func testSparseCreateReplayAfterRestartPreservesNewerContentAndHandleGeneration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let create = NamespaceRPCRequest(operation: "create", parentID: f.rootID, name: "sparse.bin", kind: .file, attributes: ["size": "8192"])
        let accepted = try required(try successful(await f.owner.handle(create)).node)
        assertEqual(accepted.size, 8192)
        var read = request("read", node: accepted.id); read.offset = 4090; read.length = 12
        assertEqual(try successful(await f.owner.handle(read)).data, Data(repeating: 0, count: 12))
        var write = request("write", node: accepted.id); write.offset = 4096; write.data = Data("newer".utf8)
        let newer = try required(try successful(await f.owner.handle(write)).node)
        let revision = try await f.store.volume().revision
        // A fresh owner has no in-memory RPC reply cache: replay must use the journal.
        let restarted = NamespaceOwner(store: f.store, sync: f.sync, directory: f.directory, readOnly: false)
        let opened = try successful(await restarted.handle(request("open", node: accepted.id)))
        let handle = try XCTUnwrap(opened.handleID)
        let replay = try successful(await restarted.handle(create))
        assertEqual(replay.node?.id, accepted.id)
        assertEqual(try await f.store.volume().revision, revision)
        var current = request("read", node: accepted.id, handle: handle); current.offset = 4096; current.length = 5
        let bytes = try successful(await restarted.handle(current))
        assertEqual(bytes.data, Data("newer".utf8)); assertEqual(bytes.generation, newer.contentGeneration)
        var conflicting = create; conflicting.attributes = ["size": "16384"]
        assertTrue((await restarted.handle(conflicting)).error != nil)
        assertEqual(try await f.store.node(accepted.id).size, 8192)
        _ = try successful(await restarted.handle(request("close", node: accepted.id, handle: handle)))
    }
    func testPauseIntentSurvivesOwnerRestartWithoutPublishingPendingRename() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try successful(await f.owner.handle(request("pause")))
        let rename = NamespaceRPCRequest(operation: "rename", nodeID: f.source.id, destinationParentID: f.target.id, destinationName: "After")
        _ = try successful(await f.owner.handle(rename))
        let sync = SyncEngine(store: f.store, content: f.content, cache: f.cache, remote: f.remote, prefix: "fixture")
        let restarted = NamespaceOwner(store: f.store, sync: sync, directory: f.directory, readOnly: false)
        await restarted.backgroundStep()
        let paused = try successful(await restarted.handle(request("status")))
        assertEqual(paused.attributes?["paused"], "true")
        assertEqual(try await f.store.operations(limit: 10).count, 1)
        assertTrue(try await f.remote.head(key: "fixture/Before/child.bin") != nil)
        assertTrue(try await f.remote.head(key: "fixture/Target/After/child.bin") == nil)
        assertEqual((await restarted.handle(request("prepareStop"))).error?.errno, EBUSY)
    }
    func testCorruptPauseIntentBlocksMutationsUntilExplicitResume() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try successful(await f.owner.handle(request("pause")))
        try Data("corrupt".utf8).write(to: f.directory.appendingPathComponent("sync-control.json"))
        let sync = SyncEngine(store: f.store, content: f.content, cache: f.cache, remote: f.remote, prefix: "fixture")
        let restarted = NamespaceOwner(store: f.store, sync: sync, directory: f.directory, readOnly: false)
        let create = NamespaceRPCRequest(operation: "create", parentID: f.rootID, name: "new", kind: .file)
        assertEqual((await restarted.handle(create)).attributes?["failureKind"], "storage.integrity")
        assertEqual((await restarted.handle(request("status"))).attributes?["failureKind"], "storage.integrity")
        await restarted.backgroundStep()
        _ = try successful(await restarted.handle(request("resume")))
        let status = try successful(await restarted.handle(request("status")))
        assertEqual(status.attributes?["paused"], "false")
        _ = try successful(await restarted.handle(NamespaceRPCRequest(operation: "create", parentID: f.rootID, name: "recovered", kind: .file)))
    }
    func testPrepareStopWaitsForPausedPinIntentAndAcceptedReadWithoutHandle() async throws {
        let f = try await fixture(readOnly: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try successful(await f.owner.handle(request("pause")))
        _ = try successful(await f.owner.handle(request("pin", node: f.child.id)))
        assertEqual((await f.owner.handle(request("prepareStop"))).error?.errno, EBUSY)
        _ = try successful(await f.owner.handle(request("unpin", node: f.child.id)))
        let blocked = BlockedReadStorage(f.remote)
        let sync = SyncEngine(store: f.store, content: f.content, cache: f.cache, remote: blocked, prefix: "fixture")
        let owner = NamespaceOwner(store: f.store, sync: sync, directory: f.directory, readOnly: true)
        await owner.backgroundStep()
        var read = request("read", node: f.child.id); read.offset = 0; read.length = 7
        let work = Task { await owner.handle(read) }
        let deadline = Date().addingTimeInterval(2)
        while !(await blocked.hasStarted()), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard await blocked.hasStarted() else { await blocked.release(); throw POSIXError(.ETIMEDOUT) }
        assertEqual((await owner.handle(request("prepareStop"))).error?.errno, EBUSY)
        await blocked.release()
        assertEqual(try successful(await work.value).data, Data("payload".utf8))
        let prepared = try successful(await owner.handle(request("prepareStop")))
        assertEqual(prepared.attributes?["safeToStop"], "true")
    }

    func testUploadRatePersistsAcrossPauseResumeAndOwnerRestart() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let limiter = UploadBandwidthLimiter(), owner = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: limiter)
        let configured = await owner.handle(.init(operation: "configureUploadRate", offset: 123_456))
        XCTAssertNil(configured.error)
        let paused = await owner.handle(.init(operation: "pause")); XCTAssertNil(paused.error)
        let restoredLimiter = UploadBandwidthLimiter(), restarted = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: restoredLimiter)
        let status = await restarted.handle(.init(operation: "status"))
        XCTAssertNil(status.error); XCTAssertEqual(status.attributes?["uploadRateBytesPerSecond"], "123456"); XCTAssertEqual(status.attributes?["paused"], "true")
        let resumed = await restarted.handle(.init(operation: "resume")); XCTAssertNil(resumed.error)
        let unlimited = await restarted.handle(.init(operation: "configureUploadRate", offset: 0)); XCTAssertNil(unlimited.error)
        let finalLimiter = UploadBandwidthLimiter(initialBytesPerSecond: 999), final = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: finalLimiter)
        let finalStatus = await final.handle(.init(operation: "status"))
        XCTAssertEqual(finalStatus.attributes?["uploadRateBytesPerSecond"], "0")
        await fixture.store.close()
    }

    func testInitialUploadRateSurvivesPauseAndInvalidSettingCannotChangeControlFile() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let limiter = UploadBandwidthLimiter(initialBytesPerSecond: 321), owner = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: limiter)
        let paused = await owner.handle(.init(operation: "pause")); XCTAssertNil(paused.error)
        let url = fixture.directory.appendingPathComponent("sync-control.json"), original = try Data(contentsOf: url)
        let invalid = await owner.handle(.init(operation: "configureUploadRate", offset: -1)); XCTAssertEqual(invalid.error?.errno, EINVAL)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let restarted = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: UploadBandwidthLimiter())
        let status = await restarted.handle(.init(operation: "status")); XCTAssertEqual(status.attributes?["uploadRateBytesPerSecond"], "321")
        await fixture.store.close()
    }

    func testConcurrentRateSettingsMatchDurableControlAndRestartedValue() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let owner = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: UploadBandwidthLimiter())
        let initial = await owner.handle(.init(operation: "configureUploadRate", offset: 77)); XCTAssertNil(initial.error)
        let restarted = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: UploadBandwidthLimiter())
        await withTaskGroup(of: NamespaceRPCResponse.self) { group in
            for rate in 100..<110 { group.addTask { await restarted.handle(.init(operation: "configureUploadRate", offset: Int64(rate))) } }
            for await response in group { XCTAssertNil(response.error) }
        }
        struct Control: Decodable { let uploadRateBytesPerSecond: Int64? }
        let saved = try CoreFileIO.readChecked(Control.self, at: fixture.directory.appendingPathComponent("sync-control.json"), maximum: 4096)
        let status = await restarted.handle(.init(operation: "status"))
        XCTAssertEqual(status.attributes?["uploadRateBytesPerSecond"], saved.uploadRateBytesPerSecond.map(String.init))
        let final = NamespaceOwner(store: fixture.store, sync: fixture.sync, directory: fixture.directory, uploadBandwidthLimiter: UploadBandwidthLimiter())
        let finalStatus = await final.handle(.init(operation: "status"))
        XCTAssertEqual(finalStatus.attributes?["uploadRateBytesPerSecond"], status.attributes?["uploadRateBytesPerSecond"])
        await fixture.store.close()
    }

}
