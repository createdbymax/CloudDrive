import XCTest
import FSKit
@testable import CloudDriveCore
@testable import CloudDriveFSAdapter

@available(macOS 26.0, *)
private actor CallbackOwner: FileSystemOwnerRPC {
    let volume: NamespaceVolume
    var values: [UUID: NamespaceNode]
    var operations: [String] = []
    var leases: Set<UUID> = []
    var attached = true
    var failClose = false
    var availabilityState = "availableOffline"
    var failAvailability = false
    var activeWrites = 0
    var maximumWrites = 0
    init() {
        let root = UUID(), source = UUID(), destination = UUID(), child = UUID()
        volume = NamespaceVolume(id: UUID(), rootID: root, binding: "synthetic", mode: .compatible, revision: 1, publishedRevision: 0)
        func item(_ id: UUID, _ inode: Int64, _ parent: UUID?, _ name: String, _ kind: NamespaceNodeKind) -> NamespaceNode {
            NamespaceNode(id: id, inode: inode, parentID: parent, name: name, kind: kind, size: kind == .file ? 7 : 0,
                          contentGeneration: 0, metadataGeneration: 1, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), deletedRevision: nil, backing: nil, stagedSnapshotID: nil)
        }
        values = [root:item(root, 2, nil, "", .directory), source:item(source, 3, root, "Before", .directory), destination:item(destination, 4, root, "Target", .directory), child:item(child, 5, source, "child.bin", .file)]
    }
    func snapshot() -> NamespaceVolume { volume }
    func observed() -> [String] { operations }
    func leaseCount() -> Int { leases.count }
    func writePeak() -> Int { maximumWrites }
    func setAvailability(_ state: String, fail: Bool = false) { availabilityState = state; failAvailability = fail }
    func isAttached() -> Bool { attached }
    func setCloseFailure(_ failure: Bool) { failClose = failure }
    func call(_ request: NamespaceRPCRequest) async throws -> NamespaceRPCResponse {
        operations.append(request.operation)
        var response = NamespaceRPCResponse(requestID: request.requestID)
        switch request.operation {
        case "availability":
            if failAvailability { throw POSIXError(.EIO) }
            response.attributes = ["availability": availabilityState]
        case "volume": response.volume = volume
        case "node": response.node = values[request.nodeID!]
        case "lookup": response.node = values.values.first { $0.parentID == request.parentID && $0.name == request.name }
        case "create":
            let node = NamespaceNode(id: UUID(), inode: Int64(values.count + 10), parentID: request.parentID,
                                     name: request.name!, kind: request.kind!, size: Int64(request.attributes?["size"] ?? "0")!,
                                     contentGeneration: 0, metadataGeneration: 1, modifiedAt: Date(),
                                     deletedRevision: nil, backing: nil, stagedSnapshotID: nil)
            values[node.id] = node; response.node = node
        case "write":
            activeWrites += 1; maximumWrites = max(maximumWrites, activeWrites)
            defer { activeWrites -= 1 }
            // Model the owner's suspended staging transaction: a second write
            // during this interval would race its generation compare-and-swap.
            try await Task.sleep(for: .milliseconds(5))
            guard activeWrites == 1 else { throw POSIXError(.ESTALE) }
            response.node = values[request.nodeID!]
        case "open":
            let handle = UUID(); leases.insert(handle); response.handleID = handle
        case "close":
            if failClose { throw POSIXError(.EIO) }
            guard let handle = request.handleID, leases.remove(handle) != nil else { throw POSIXError(.EBADF) }
        case "attach": attached = true
        case "detach":
            guard leases.isEmpty else { throw POSIXError(.EBUSY) }
            attached = false
        case "rename":
            guard let old = values[request.nodeID!], let parent = request.destinationParentID, let name = request.destinationName else { throw POSIXError(.EINVAL) }
            let moved = NamespaceNode(id: old.id, inode: old.inode, parentID: parent, name: name, kind: old.kind, size: old.size, contentGeneration: old.contentGeneration, metadataGeneration: old.metadataGeneration+1, modifiedAt: old.modifiedAt, deletedRevision: nil, backing: old.backing, stagedSnapshotID: old.stagedSnapshotID)
            values[old.id] = moved; response.node = moved; response.revision = 2
        default: throw POSIXError(.ENOTSUP)
        }
        if ["node", "lookup"].contains(request.operation), response.node == nil { throw POSIXError(.ENOENT) }
        return response
    }
}

@available(macOS 26.0, *)
private struct AttributeStoreOwner: FileSystemOwnerRPC {
    let store: NamespaceStore
    func call(_ request: NamespaceRPCRequest) async throws -> NamespaceRPCResponse {
        var result = NamespaceRPCResponse(requestID: request.requestID)
        switch request.operation {
        case "node": result.node = try await store.node(XCTUnwrap(request.nodeID))
        case "lookup": result.node = try await store.lookup(parentID: XCTUnwrap(request.parentID), name: XCTUnwrap(request.name))
        case "setxattr":
            _ = try await store.setXattr(nodeID: XCTUnwrap(request.nodeID), name: XCTUnwrap(request.name), value: request.data,
                                         policy: XCTUnwrap(request.attributes?["policy"]), operationID: request.requestID)
        default: throw POSIXError(.ENOTSUP)
        }
        return result
    }
}

final class VolumeCallbackTests: XCTestCase {
    func testCreationConsumesOnlyCommittedFileSizeAndAdvertisesLargeFiles() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let owner = CallbackOwner(), identity = await owner.snapshot()
        let volume = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: false)
        XCTAssertTrue(volume.supportedVolumeCapabilities.supports2TBFiles)
        XCTAssertGreaterThan(volume.maximumFileSize, 4 * 1024 * 1024 * 1024)
        func create(_ adapter: CloudDriveFSVolume, _ request: FSItem.SetAttributesRequest, _ type: FSItem.ItemType) async -> Error? {
            await withCheckedContinuation { continuation in
                adapter.createItem(named: FSFileName(string: UUID().uuidString), type: type,
                                   inDirectory: CloudDriveFSItem(nodeID: identity.rootID), attributes: request) { _, _, error in
                    continuation.resume(returning: error)
                }
            }
        }
        for length: UInt64 in [0, 8192] {
            let request = FSItem.SetAttributesRequest(); request.size = length
            request.modifyTime = timespec(tv_sec: 123, tv_nsec: 0)
            let error = await create(volume, request, .file)
            XCTAssertNil(error)
            XCTAssertTrue(request.consumedAttributes.contains(.size))
            XCTAssertFalse(request.consumedAttributes.contains(.modifyTime))
        }
        let folderAttributes = FSItem.SetAttributesRequest(); folderAttributes.size = 0
        let folderError = await create(volume, folderAttributes, .directory)
        XCTAssertNil(folderError); XCTAssertFalse(folderAttributes.consumedAttributes.contains(.size))
        let readOnly = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: true)
        let failed = FSItem.SetAttributesRequest(); failed.size = 8192
        let error = await create(readOnly, failed, .file)
        XCTAssertEqual((error as NSError?)?.code, Int(EROFS))
        XCTAssertTrue(failed.consumedAttributes.isEmpty)
    }
    @available(macOS 26.0, *)
    private func lookup(_ volume: CloudDriveFSVolume, _ name: String, _ parent: FSItem) async throws -> FSItem {
        try await withCheckedThrowingContinuation { continuation in
            volume.lookupItem(named: FSFileName(string: name), inDirectory: parent) { item, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: POSIXError(.EIO)) }
            }
        }
    }
    func testManagedXattrCallbacksRouteNativeAndLegacyItemsSeparately() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NamespaceStore(directory: dir, binding: "xattr-callback", mode: .managed)
        let volume = try await store.volume()
        let folder = CloudDriveFSItem(nodeID: volume.rootID)
        try await store.importEntries([.init(path: "legacy")])
        _ = try await store.create(parentID: volume.rootID, name: "fresh", kind: .file, nativeXattrs: true)
        let adapter = CloudDriveFSVolume(owner: AttributeStoreOwner(store: store), volume: volume, readOnly: false)
        let file = try await lookup(adapter, "fresh", folder), old = try await lookup(adapter, "legacy", folder)
        let attr = FSFileName(string: "com.apple.provenance"), bytes = Data([1, 0, 2, 255])
        XCTAssertTrue(adapter.supportedXattrNames(for: file).contains { $0.string == attr.string })
        XCTAssertFalse(adapter.supportedXattrNames(for: old).contains { $0.string == attr.string })
        XCTAssertFalse(adapter.supportedXattrNames(for: file).contains { $0.string == "com.apple.ResourceFork" })
        func set(_ value: Data?, _ policy: FSVolume.SetXattrPolicy) async -> Int {
            await withCheckedContinuation { continuation in
                adapter.setXattr(named: attr, to: value, on: file, policy: policy) { continuation.resume(returning: ($0 as NSError?)?.code ?? 0) }
            }
        }
        let created = await set(bytes, .mustCreate), duplicate = await set(bytes, .mustCreate)
        XCTAssertEqual(created, 0); XCTAssertEqual(duplicate, Int(EEXIST))
        let actual: Data? = try await withCheckedThrowingContinuation { continuation in
            adapter.getXattr(named: attr, of: file) { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
        XCTAssertEqual(actual, bytes)
        let listed: [FSFileName]? = try await withCheckedThrowingContinuation { continuation in
            adapter.listXattrs(of: file) { names, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: names) }
            }
        }
        XCTAssertTrue(try XCTUnwrap(listed).contains { $0.string == attr.string })
        XCTAssertFalse(try XCTUnwrap(listed).contains { $0.string == CloudDriveFSVolume.availabilityXattr })
        let replaced = await set(Data(), .mustReplace), deleted = await set(nil, .delete), missing = await set(nil, .delete)
        XCTAssertEqual(replaced, 0); XCTAssertEqual(deleted, 0); XCTAssertEqual(missing, Int(ENOATTR))
    }
    func testComputedAvailabilityXattrIsStateOnlyReadOnlyAndFailsUnknown() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let owner = CallbackOwner(), identity = await owner.snapshot()
        let volume = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: false)
        let item = CloudDriveFSItem(nodeID: identity.rootID)
        let itemAttributes: FSItem.Attributes = try await withCheckedThrowingContinuation { continuation in
            volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { attributes, error in
                if let error { continuation.resume(throwing: error) }
                else if let attributes { continuation.resume(returning: attributes) }
                else { continuation.resume(throwing: POSIXError(.EIO)) }
            }
        }
        XCTAssertTrue(itemAttributes.supportsLimitedXAttrs)
        func get(_ name: String) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                volume.getXattr(named: FSFileName(string: name), of: item) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value ?? Data()) }
                }
            }
        }
        for state in ["remoteOnly", "downloading", "availableOffline", "attention", "unknown"] {
            await owner.setAvailability(state)
            let data = try await get(CloudDriveFSVolume.availabilityXattr)
            XCTAssertEqual(data, Data(state.utf8))
        }
        await owner.setAvailability("invalid provider value")
        let invalid = try await get(CloudDriveFSVolume.availabilityXattr)
        XCTAssertEqual(invalid, Data("unknown".utf8))
        await owner.setAvailability("availableOffline", fail: true)
        let failed = try await get(CloudDriveFSVolume.availabilityXattr)
        XCTAssertEqual(failed, Data("unknown".utf8))
        do { _ = try await get("com.apple.FinderInfo"); XCTFail("Arbitrary attributes unsupported") }
        catch { XCTAssertEqual((error as NSError).code, Int(ENOATTR)) }
        let code: Int = await withCheckedContinuation { continuation in
            volume.setXattr(named: FSFileName(string: CloudDriveFSVolume.availabilityXattr), to: Data(), on: item, policy: .alwaysSet) {
                continuation.resume(returning: ($0 as NSError?)?.code ?? 0)
            }
        }
        XCTAssertEqual(code, Int(ENOTSUP))
        XCTAssertEqual(volume.supportedXattrNames(for: item).map(\.string), [CloudDriveFSVolume.availabilityXattr])
        let listed: [FSFileName]? = try await withCheckedThrowingContinuation { continuation in
            volume.listXattrs(of: item) { names, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: names) }
            }
        }
        XCTAssertTrue(try XCTUnwrap(listed).isEmpty)
    }
    func testConcurrentKernelWritesAreSerializedThroughAllFrameChunks() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let owner = CallbackOwner(), identity = await owner.snapshot()
        let volume = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: false)
        let folder = try await lookup(volume, "Before", CloudDriveFSItem(nodeID: identity.rootID))
        let child = try await lookup(volume, "child.bin", folder)
        let payload = Data(repeating: 42, count: 1_048_576 + 17)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let count: Int = try await withCheckedThrowingContinuation { continuation in
                        volume.write(contents: payload, to: child, at: off_t(index * payload.count)) { count, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: count) }
                        }
                    }
                    XCTAssertEqual(count, payload.count)
                }
            }
            try await group.waitForAll()
        }
        let peak = await owner.writePeak(), operations = await owner.observed()
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(operations.filter { $0 == "write" }.count, 16)
    }
    func testFolderRenamePreservesExistingChildIdentityAndNeverRequestsContent() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let owner = CallbackOwner(), identity = await owner.snapshot()
        let volume = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: false)
        let rootResponse = try await owner.call(NamespaceRPCRequest(operation: "node", nodeID: identity.rootID))
        let root = try XCTUnwrap(rootResponse.node)
        let rootItem = CloudDriveFSItem(nodeID: root.id)
        let before = try await lookup(volume, "Before", rootItem)
        let child = try await lookup(volume, "child.bin", before)
        let target = try await lookup(volume, "Target", rootItem)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            volume.renameItem(before, inDirectory: rootItem, named: FSFileName(string: "Before"), to: FSFileName(string: "After"), inDirectory: target, overItem: nil) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let after = try await lookup(volume, "After", target)
        let sameChild = try await lookup(volume, "child.bin", after)
        XCTAssertTrue(before === after)
        XCTAssertTrue(child === sameChild)
        let observed = await owner.observed()
        XCTAssertEqual(observed.filter { $0 == "rename" }.count, 1)
        XCTAssertFalse(observed.contains("read")); XCTAssertFalse(observed.contains("write"))
    }
    func testReadOnlyVolumeRejectsRenameBeforeSendingMutationToOwner() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let owner = CallbackOwner(), identity = await owner.snapshot()
        let volume = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: true)
        let root = CloudDriveFSItem(nodeID: identity.rootID)
        let source = try await lookup(volume, "Before", root)
        let code: Int = await withCheckedContinuation { continuation in
            volume.renameItem(source, inDirectory: root, named: FSFileName(string: "Before"), to: FSFileName(string: "After"), inDirectory: root, overItem: nil) { _, error in
                continuation.resume(returning: (error as NSError?)?.code ?? 0)
            }
        }
        XCTAssertEqual(code, Int(EROFS))
        let observed = await owner.observed()
        XCTAssertFalse(observed.contains("rename"))
    }
    func testUnmountClosesRetainedHandlesBeforeDetachingOwner() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let owner = CallbackOwner(), identity = await owner.snapshot()
        let volume = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: false)
        let root = CloudDriveFSItem(nodeID: identity.rootID)
        let source = try await lookup(volume, "Before", root)
        let child = try await lookup(volume, "child.bin", source)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            volume.openItem(child, modes: .read) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        let before = await owner.leaseCount(); XCTAssertEqual(before, 1)
        await withCheckedContinuation { continuation in volume.unmount { continuation.resume() } }
        let count = await owner.leaseCount(), attached = await owner.isAttached(), operations = await owner.observed()
        XCTAssertEqual(count, 0); XCTAssertFalse(attached)
        XCTAssertLessThan(try XCTUnwrap(operations.firstIndex(of: "close")), try XCTUnwrap(operations.firstIndex(of: "detach")))
    }
    func testFailedCloseCannotReportOwnerDetachedAndCanBeRetried() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FSKit adapter requires macOS 26") }
        let owner = CallbackOwner(), identity = await owner.snapshot()
        let volume = CloudDriveFSVolume(owner: owner, volume: identity, readOnly: false)
        let root = CloudDriveFSItem(nodeID: identity.rootID)
        let source = try await lookup(volume, "Before", root), child = try await lookup(volume, "child.bin", source)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            volume.openItem(child, modes: .read) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        await owner.setCloseFailure(true)
        await withCheckedContinuation { continuation in volume.unmount { continuation.resume() } }
        let retained = await owner.leaseCount(), attached = await owner.isAttached(), first = await owner.observed()
        XCTAssertEqual(retained, 1); XCTAssertTrue(attached); XCTAssertFalse(first.contains("detach"))
        await owner.setCloseFailure(false)
        await withCheckedContinuation { continuation in volume.unmount { continuation.resume() } }
        let final = await owner.leaseCount(), finalAttached = await owner.isAttached()
        XCTAssertEqual(final, 0); XCTAssertFalse(finalAttached)
    }

}
