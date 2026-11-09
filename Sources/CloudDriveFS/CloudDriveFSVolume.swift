import Foundation
import FSKit
import CloudDriveCore
import Darwin
import os

/// The adapter owns kernel objects and directory cursors only. The authenticated
/// engine owns every accepted namespace mutation, byte and recovery record.
@available(macOS 26.0, *)
public protocol FileSystemOwnerRPC: Sendable {
    var preferredWriteSize: Int { get }
    func call(_ request: NamespaceRPCRequest) async throws -> NamespaceRPCResponse
}

@available(macOS 26.0, *)
extension FileSystemOwnerRPC { public var preferredWriteSize: Int { 1_048_576 } }

@available(macOS 26.0, *)
extension UnixSocketRPCClient: FileSystemOwnerRPC {
    public var preferredWriteSize: Int { min(NamespaceOwnerDescriptor.maximumWriteBytes, max(1_048_576, descriptor.rawWriteLimit ?? 1_048_576)) }
}

@available(macOS 26.0, *)
final class CloudDriveFSItem: FSItem, @unchecked Sendable {
    let nodeID: UUID
    let nativeXattrs: Bool
    init(nodeID: UUID, nativeXattrs: Bool = false) { self.nodeID = nodeID; self.nativeXattrs = nativeXattrs; super.init() }
}

/// Cookies name a validated continuation, rather than an offset into a mutable
/// array. An expired or changed directory is restarted, never silently skipped.
enum FileSystemCursorFailure: Error { case invalid }

struct FileSystemDirectoryCursor: Equatable, Sendable {
    let directoryID: UUID
    let revision: Int64
    let after: String?
    let dotIndex: Int
    func validate(pageRevision: Int64, verifier: UInt64) throws {
        guard revision >= 0, revision == pageRevision,
              verifier == 0 || verifier == UInt64(revision) + 1 else { throw FileSystemCursorFailure.invalid }
    }
}

final class FileSystemCursorTable: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 1
    private var entries: [UInt64: FileSystemDirectoryCursor] = [:]
    private var order: [UInt64] = []
    private let capacity: Int
    init(capacity: Int = 4096) { self.capacity = max(1, capacity) }
    func insert(_ cursor: FileSystemDirectoryCursor) -> UInt64 {
        lock.withLock {
            sequence &+= 1
            if sequence == 0 { sequence = 1 }
            entries[sequence] = cursor; order.append(sequence)
            while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
            return sequence
        }
    }
    func cursor(_ value: UInt64, directory: UUID) throws -> FileSystemDirectoryCursor {
        try lock.withLock {
            guard let cursor = entries[value], cursor.directoryID == directory else {
                throw FileSystemCursorFailure.invalid
            }
            return cursor
        }
    }
    func removeAll() { lock.withLock { entries.removeAll(); order.removeAll() } }
}

private actor FileSystemHandleGate {
    private var admitted: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    func acquire(_ node: UUID) async {
        if admitted.insert(node).inserted { return }
        await withCheckedContinuation { waiters[node, default: []].append($0) }
    }
    func release(_ node: UUID) {
        if var queued = waiters[node], !queued.isEmpty {
            let next = queued.removeFirst(); waiters[node] = queued; next.resume()
        } else { waiters.removeValue(forKey: node); admitted.remove(node) }
    }
}

@available(macOS 26.0, *)
public final class CloudDriveFSVolume: FSVolume, FSVolume.Operations, FSVolume.OpenCloseOperations, FSVolume.ReadWriteOperations, FSVolume.XattrOperations, @unchecked Sendable {
    private let owner: any FileSystemOwnerRPC
    private let identity: NamespaceVolume
    private let readOnly: Bool
    private let lock = NSLock()
    private var items: [UUID: CloudDriveFSItem] = [:]
    private var nodes: [UUID: NamespaceNode] = [:]
    private var handles: [UUID: UUID] = [:]
    private let cursors = FileSystemCursorTable()
    private let handleGate = FileSystemHandleGate()
    private var localAvailableBytes: UInt64 = 0
    private var capacitySampledAt: Date?
    private var capacityPolling: Task<Void, Never>?
    private var attached = false
    private var detaching = false
    private let signposter = OSSignposter(subsystem: "local.bucketdrive.app.filesystem", category: "OwnerRPC")
    private func sampleCapacity() async throws {
        let response: NamespaceRPCResponse
        do { response = try await owner.call(NamespaceRPCRequest(operation: "capacity")) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOTSUP) {
            response = try await owner.call(NamespaceRPCRequest(operation: "status"))
        }
        guard let raw = response.attributes?["availableBytes"], let bytes = UInt64(raw) else { throw POSIXError(.EIO) }
        lock.withLock { localAvailableBytes = bytes; capacitySampledAt = Date() }
    }

    private func beginCapacityPolling() {
        let polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let owner = self else { return }
                try? await owner.sampleCapacity()
            }
        }
        lock.withLock { capacityPolling?.cancel(); capacityPolling = polling }
    }
    private func endCapacityPolling() { lock.withLock { capacityPolling?.cancel(); capacityPolling = nil } }
    deinit { capacityPolling?.cancel() }

    public init(owner: any FileSystemOwnerRPC, volume: NamespaceVolume, readOnly: Bool) {
        self.owner = owner; self.identity = volume; self.readOnly = readOnly
        super.init(volumeID: FSVolume.Identifier(uuid: volume.id), volumeName: FSFileName(string: "CloudDrive"))
    }

    public var maximumLinkCount: Int { 1 }
    public var maximumNameLength: Int { 255 }
    public var maximumFileSize: UInt64 { identity.mode == .managed ? UInt64(SyncEngine.managedFileLimit) : 5 * 1024 * 1024 * 1024 }
    public var maximumXattrSize: Int { identity.canCreateNativeXattrs == true ? ManagedXattrs.maximumValueBytes : 64 }
    public var restrictsOwnershipChanges: Bool { true }
    public var truncatesLongNames: Bool { false }
    public var enableOpenUnlinkEmulation: Bool { false }
    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let result = FSVolume.SupportedCapabilities()
        result.supportsPersistentObjectIDs = true
        result.supports64BitObjectIDs = true
        result.supportsJournal = true; result.supportsActiveJournal = true
        result.supportsSparseFiles = true; result.supportsZeroRuns = true
        // FSKit uses this flag for files larger than 4 GiB; maximumFileSize
        // separately communicates this volume's actual limit.
        result.supports2TBFiles = true
        result.doesNotSupportImmutableFiles = true
        result.doesNotSupportSettingFilePermissions = true
        result.caseFormat = .insensitiveCasePreserving
        return result
    }
    public var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "clouddrive")
        result.blockSize = 4096; result.ioSize = owner.preferredWriteSize
        // The owner reports writeback admission; bucket quota is not exposed by R2.
        result.availableBytes = lock.withLock { guard let time = capacitySampledAt, Date().timeIntervalSince(time) < 5 else { return 0 }; return localAvailableBytes }
        result.freeBytes = result.availableBytes; result.totalBytes = result.availableBytes
        return result
    }

    private func rpc(_ request: NamespaceRPCRequest) async throws -> NamespaceRPCResponse {
        // Instruments can separate owner round-trip latency from Finder preflight
        // and rendering. Only the fixed operation name is public; never emit node
        // names, paths, IPC tokens, credential fields or byte payloads.
        let interval = signposter.beginInterval("OwnerRPC", id: signposter.makeSignpostID(), "operation=\(request.operation, privacy: .public)")
        defer { signposter.endInterval("OwnerRPC", interval) }
        return try await owner.call(request)
    }
    private func id(_ item: FSItem) throws -> UUID {
        guard let item = item as? CloudDriveFSItem else { throw POSIXError(.ESTALE) }
        return item.nodeID
    }
    private func name(_ value: FSFileName) throws -> String {
        guard let name = value.string, !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw POSIXError(.EINVAL) }
        return name
    }
    private func writable() throws { if readOnly { throw POSIXError(.EROFS) }; if lock.withLock({ detaching }) { throw POSIXError(.ENOTCONN) } }
    private func cached(_ node: NamespaceNode) -> CloudDriveFSItem {
        lock.withLock {
            nodes[node.id] = node
            if let item = items[node.id] { return item }
            let item = CloudDriveFSItem(nodeID: node.id, nativeXattrs: node.xattrs != nil); items[node.id] = item; return item
        }
    }
    private func publish(_ node: NamespaceNode, _ reply: (CloudDriveFSItem) -> Void) {
        // FSKit registers a returned reference during the reply. Keep that step
        // in the same critical section as tryReclaim and cache identity lookup.
        lock.withLock {
            nodes[node.id] = node
            let item = items[node.id] ?? CloudDriveFSItem(nodeID: node.id, nativeXattrs: node.xattrs != nil)
            items[node.id] = item
            reply(item)
        }
    }
    private func node(_ nodeID: UUID) async throws -> NamespaceNode {
        let response = try await rpc(NamespaceRPCRequest(operation: "node", nodeID: nodeID))
        guard let node = response.node else { throw POSIXError(.EIO) }
        _ = cached(node); return node
    }
    private func attributes(_ node: NamespaceNode) throws -> FSItem.Attributes {
        guard node.inode >= 2, node.size >= 0 else { throw POSIXError(.EIO) }
        return try lock.withLock {
            let result = FSItem.Attributes()
            result.type = node.kind == .directory ? .directory : .file
            result.flags = 0
            result.mode = node.kind == .directory ? 0o755 : 0o644
            result.uid = getuid(); result.gid = getgid(); result.linkCount = 1
            result.fileID = FSItem.Identifier(UInt64(node.inode))
            if let parentID = node.parentID {
                guard let parent = nodes[parentID] else { throw POSIXError(.ESTALE) }
                result.parentID = FSItem.Identifier(UInt64(parent.inode))
            } else { result.parentID = .rootDirectory }
            result.size = UInt64(node.size); result.allocSize = UInt64(node.size)
            let seconds = node.modifiedAt.timeIntervalSince1970
            let time = timespec(tv_sec: Int(seconds.rounded(.down)), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1_000_000_000))
            result.modifyTime = time; result.changeTime = time; result.birthTime = time
            result.accessTime = time; result.addedTime = time
            result.supportsLimitedXAttrs = true
            result.inhibitKernelOffloadedIO = true
            return result
        }
    }
    private func cacheParent(of node: NamespaceNode) async throws {
        if let parentID = node.parentID, lock.withLock({ nodes[parentID] == nil }) { _ = try await self.node(parentID) }
    }
    public func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, Error?) -> Void) {
        Task {
            do { let root = try await node(identity.rootID); publish(root) { reply($0, nil) } }
            catch { reply(nil, error) }
        }
    }
    public func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping (Error?) -> Void) {
        // FSKit has already synchronized and unmounted; no network I/O here.
        endCapacityPolling()
        lock.withLock { items.removeAll(); nodes.removeAll(); attached = false }
        cursors.removeAll(); reply(nil)
    }
    public func mount(options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        Task {
            do { _ = try await rpc(NamespaceRPCRequest(operation: "sync")); try await sampleCapacity(); _ = try await rpc(NamespaceRPCRequest(operation: "attach")); lock.withLock { attached = true; detaching = false }; beginCapacityPolling(); reply(nil) }
            catch { reply(error) }
        }
    }
    public func unmount(replyHandler reply: @escaping () -> Void) {
        // This callback cannot return an error. A failed authenticated close/detach
        // therefore leaves the owner's leases/attached state intact and unsafe to
        // terminate. It never turns an unknown cleanup result into cloud success.
        endCapacityPolling()
        lock.withLock { detaching = true }
        Task {
            do {
                let opened = lock.withLock { Array(handles.keys) }
                for nodeID in opened {
                    await handleGate.acquire(nodeID)
                    do {
                        if let handle = lock.withLock({ handles[nodeID] }) {
                            _ = try await rpc(NamespaceRPCRequest(operation: "close", nodeID: nodeID, handleID: handle))
                            _ = lock.withLock { handles.removeValue(forKey: nodeID) }
                        }
                        await handleGate.release(nodeID)
                    } catch { await handleGate.release(nodeID); throw error }
                }
                _ = try await rpc(NamespaceRPCRequest(operation: "detach"))
                lock.withLock { attached = false }
            } catch {
                // Owner status remains the source of truth for failed cleanup.
            }
            cursors.removeAll(); reply()
        }
    }
    static let availabilityXattr = "com.clouddrive.availability"
    public func supportedXattrNames(for item: FSItem) -> [FSFileName] {
        let persisted = (item as? CloudDriveFSItem)?.nativeXattrs == true ? ManagedXattrs.names : []
        return ([Self.availabilityXattr] + persisted).map { FSFileName(string: $0) }
    }
    public func getXattr(named name: FSFileName, of item: FSItem, replyHandler reply: @escaping (Data?, Error?) -> Void) {
        if name.string != Self.availabilityXattr {
            guard let key = name.string, (item as? CloudDriveFSItem)?.nativeXattrs == true,
                  ManagedXattrs.names.contains(key) else { reply(nil, POSIXError(.ENOATTR)); return }
            Task {
                do {
                    guard let value = try await node(id(item)).xattrs?[key] else { throw POSIXError(.ENOATTR) }
                    reply(value, nil)
                } catch { reply(nil, error) }
            }
            return
        }
        Task {
            var state = "unknown"
            if let nodeID = try? id(item),
               let response = try? await rpc(NamespaceRPCRequest(operation: "availability", nodeID: nodeID)),
               response.error == nil, let value = response.attributes?["availability"],
               ["remoteOnly", "downloading", "availableOffline", "attention", "unknown"].contains(value) {
                state = value
            }
            reply(Data(state.utf8), nil)
        }
    }
    public func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy, replyHandler reply: @escaping (Error?) -> Void) {
        guard let key = name.string, (item as? CloudDriveFSItem)?.nativeXattrs == true,
              ManagedXattrs.names.contains(key) else { reply(POSIXError(.ENOTSUP)); return }
        Task {
            do {
                try writable()
                let action: String
                switch policy {
                case .alwaysSet: action = "set"
                case .mustCreate: action = "create"
                case .mustReplace: action = "replace"
                case .delete: action = "delete"
                @unknown default: throw POSIXError(.EINVAL)
                }
                _ = try await rpc(NamespaceRPCRequest(operation: "setxattr", nodeID: id(item), name: key,
                                                      data: value, attributes: ["policy": action]))
                reply(nil)
            } catch { reply(error) }
        }
    }
    public func listXattrs(of item: FSItem, replyHandler reply: @escaping ([FSFileName]?, Error?) -> Void) {
        // Finder copies enumerable attributes. Availability is a property of this mount
        // and remains readable by name for badges, including on imported items.
        guard (item as? CloudDriveFSItem)?.nativeXattrs == true else { reply([], nil); return }
        Task {
            do {
                let values = try await node(id(item)).xattrs ?? [:]
                reply(values.keys.sorted().map { FSFileName(string: $0) }, nil)
            } catch { reply(nil, error) }
        }
    }

    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping (Error?) -> Void) {
        Task { do { _ = try await rpc(NamespaceRPCRequest(operation: "sync")); try await sampleCapacity(); reply(nil) } catch { reply(error) } }
    }
    public func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        do {
            let nodeID = try id(item)
            // Older FSKit lacks reference-safe reclaim. Keep the cached item until teardown.
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                lock.withLock {
                    _ = item.tryReclaim {
                        self.items.removeValue(forKey: nodeID)
                        self.nodes.removeValue(forKey: nodeID)
                    }
                }
            }
            #endif
            reply(nil)
        } catch { reply(error) }
    }
    public func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        Task {
            do {
                let parent = try id(directory), requested = try self.name(name)
                let value: NamespaceNode
                if requested == "." { value = try await node(parent) }
                else if requested == ".." { let current = try await node(parent); value = try await node(current.parentID ?? identity.rootID) }
                else {
                    let response = try await rpc(NamespaceRPCRequest(operation: "lookup", parentID: parent, name: requested))
                    guard let found = response.node else { throw POSIXError(.ENOENT) }; value = found
                }
                publish(value) { reply($0, FSFileName(string: value.name.isEmpty ? "." : value.name), nil) }
            } catch { reply(nil, nil, error) }
        }
    }
    public func getAttributes(_ request: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        Task { do { let value = try await node(id(item)); try await cacheParent(of: value); reply(try attributes(value), nil) } catch { reply(nil, error) } }
    }
    public func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        Task {
            do {
                try writable(); let nodeID = try id(item)
                await handleGate.acquire(nodeID)
                do {
                var values: [String: String] = [:]
                if request.isValid(.size) { values["size"] = String(request.size) }
                if request.isValid(.modifyTime) { values["modifiedAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(request.modifyTime.tv_sec) + Double(request.modifyTime.tv_nsec) / 1_000_000_000)) }
                let value: NamespaceNode
                if values.isEmpty { value = try await node(nodeID) }
                else {
                    var command = NamespaceRPCRequest(operation: "setattrs", nodeID: nodeID)
                    command.attributes = values; command.handleID = lock.withLock { handles[nodeID] }
                    let response = try await rpc(command); guard let updated = response.node else { throw POSIXError(.EIO) }; value = updated
                    if values["size"] != nil { request.consumedAttributes.insert(.size) }
                    if values["modifiedAt"] != nil { request.consumedAttributes.insert(.modifyTime) }
                    _ = cached(value)
                }
                try await cacheParent(of: value)
                let result = try attributes(value)
                await handleGate.release(nodeID); reply(result, nil)
                } catch { await handleGate.release(nodeID); throw error }
            } catch { reply(nil, error) }
        }
    }
    public func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        Task {
            do {
                try writable(); guard type == .file || type == .directory else { throw POSIXError(.ENOTSUP) }
                var request = NamespaceRPCRequest(operation: "create", parentID: try id(directory), name: try self.name(name))
                request.kind = type == .file ? .file : .directory
                if type == .file, attributes.isValid(.size), attributes.size != 0 { request.attributes = ["size": String(attributes.size)] }
                if identity.canCreateNativeXattrs == true {
                    var options = request.attributes ?? [:]; options["xattrs"] = "native"; request.attributes = options
                }
                let response = try await rpc(request); guard let value = response.node else { throw POSIXError(.EIO) }
                // The owner has committed the requested initial length (including
                // zero). Report it consumed so FSKit need not apply it again.
                if type == .file, attributes.isValid(.size), value.size == attributes.size {
                    attributes.consumedAttributes.insert(.size)
                }
                publish(value) { reply($0, FSFileName(string: value.name), nil) }
            } catch { reply(nil, nil, error) }
        }
    }
    public func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) { reply(nil, nil, POSIXError(.ENOTSUP)) }
    public func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) { reply(nil, POSIXError(.ENOTSUP)) }
    public func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) { reply(nil, POSIXError(.ENOTSUP)) }
    public func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        Task {
            do {
                try writable()
                var request = NamespaceRPCRequest(operation: "rename", nodeID: try id(item), parentID: try id(sourceDirectory), name: try name(sourceName), destinationParentID: try id(destinationDirectory), destinationName: try name(destinationName))
                request.replace = overItem != nil
                let response = try await rpc(request)
                if let node = response.node { _ = cached(node) }
                // The engine's durable local commit is the acknowledgement boundary.
                reply(FSFileName(string: try name(destinationName)), nil)
            } catch { reply(nil, error) }
        }
    }
    public func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        Task { do { try writable(); _ = try await rpc(NamespaceRPCRequest(operation: "remove", nodeID: try id(item), parentID: try id(directory), name: try self.name(name))); reply(nil) } catch { reply(error) } }
    }
    public func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        Task {
            do {
                let nodeID = try id(directory)
                let previous = cookie.rawValue == 0 ? nil : try cursors.cursor(cookie.rawValue, directory: nodeID)
                let needsDots = attributes == nil && (previous?.dotIndex ?? 0) < 2
                var request = NamespaceRPCRequest(operation: "list", parentID: nodeID, cookie: previous?.after, limit: 1024)
                if needsDots { request.attributes = ["dotInodes": "true"] }
                let response = try await rpc(request)
                guard let entries = response.nodes, let revision = response.revision, revision >= 0 else { throw POSIXError(.EIO) }
                let cursor = previous ?? FileSystemDirectoryCursor(directoryID: nodeID, revision: revision, after: nil, dotIndex: 0)
                try cursor.validate(pageRevision: revision, verifier: verifier.rawValue)
                let pageVerifier = FSDirectoryVerifier(UInt64(revision) + 1)
                if needsDots {
                    let dot: UInt64, parent: UInt64
                    if let d = response.attributes?["directoryInode"].flatMap(UInt64.init),
                       let p = response.attributes?["parentInode"].flatMap(UInt64.init), d >= 2, p >= 2 {
                        dot = d; parent = p
                    } else {
                        // An older engine returns entries without the two inode numbers.
                        let current = try await node(nodeID), up = try await node(current.parentID ?? identity.rootID)
                        let check = try await rpc(NamespaceRPCRequest(operation: "volume"))
                        guard check.volume?.revision == revision else { throw FileSystemCursorFailure.invalid }
                        dot = UInt64(current.inode); parent = UInt64(up.inode)
                    }
                    for index in cursor.dotIndex..<2 {
                        let next = cursors.insert(FileSystemDirectoryCursor(directoryID: nodeID, revision: revision, after: nil, dotIndex: index + 1))
                        if !packer.packEntry(name: FSFileName(string: index == 0 ? "." : ".."), itemType: .directory, itemID: FSItem.Identifier(index == 0 ? dot : parent), nextCookie: FSDirectoryCookie(next), attributes: nil) { reply(pageVerifier, nil); return }
                    }
                }
                for entry in entries {
                    _ = cached(entry)
                    let next = cursors.insert(FileSystemDirectoryCursor(directoryID: nodeID, revision: revision, after: entry.id.uuidString, dotIndex: 2))
                    if !packer.packEntry(name: FSFileName(string: entry.name), itemType: entry.kind == .directory ? .directory : .file, itemID: FSItem.Identifier(UInt64(entry.inode)), nextCookie: FSDirectoryCookie(next), attributes: attributes == nil ? nil : try self.attributes(entry)) { break }
                }
                reply(pageVerifier, nil)
            } catch is FileSystemCursorFailure { reply(verifier, FSError(.invalidDirectoryCookie)) }
            catch { reply(verifier, error) }
        }
    }
    public func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        Task {
            do {
                if modes.contains(.write) { try writable() }
                let nodeID = try id(item)
                await handleGate.acquire(nodeID)
                do {
                    if lock.withLock({ handles[nodeID] == nil }) {
                        var request = NamespaceRPCRequest(operation: "open", nodeID: nodeID); request.attributes = ["writable": modes.contains(.write) ? "true" : "false", "bufferedWrites": "true"]
                        let response = try await rpc(request); guard let handle = response.handleID else { throw POSIXError(.EIO) }
                        lock.withLock { handles[nodeID] = handle }
                    }
                    await handleGate.release(nodeID); reply(nil)
                } catch { await handleGate.release(nodeID); reply(error) }
            } catch { reply(error) }
        }
    }
    public func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        Task {
            do {
                let nodeID = try id(item)
                if modes.contains(.write) { reply(nil); return }
                await handleGate.acquire(nodeID)
                do {
                    if !modes.isEmpty {
                        _ = try await rpc(NamespaceRPCRequest(operation: "sync"))
                    } else if let handle = lock.withLock({ handles[nodeID] }) {
                        var request = NamespaceRPCRequest(operation: "close", nodeID: nodeID); request.handleID = handle
                        _ = try await rpc(request); _ = lock.withLock { handles.removeValue(forKey: nodeID) }
                    }
                    await handleGate.release(nodeID); reply(nil)
                } catch { await handleGate.release(nodeID); reply(error) }
            } catch { reply(error) }
        }
    }
    public func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, Error?) -> Void) {
        Task {
            var count = 0
            do {
                guard offset >= 0, length >= 0, offset <= Int64.max - Int64(length) else { throw POSIXError(.EINVAL) }
                let nodeID = try id(item)
                // Frames remain bounded even when the kernel asks for a large read.
                while count < length {
                    var request = NamespaceRPCRequest(operation: "read", nodeID: nodeID, offset: offset + Int64(count), length: min(length - count, 1024 * 1024)); request.handleID = lock.withLock { handles[nodeID] }
                    let response = try await rpc(request); guard let data = response.data, data.count <= request.length! else { throw POSIXError(.EIO) }
                    try buffer.withUnsafeMutableBytes { destination in
                        guard destination.count >= count + data.count else { throw POSIXError(.EIO) }
                        if !data.isEmpty { data.withUnsafeBytes { bytes in destination.baseAddress!.advanced(by: count).copyMemory(from: bytes.baseAddress!, byteCount: data.count) } }
                    }
                    count += data.count; if data.count < request.length! { break }
                }
                reply(count, nil)
            } catch { reply(count, error) }
        }
    }
    public func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, Error?) -> Void) {
        Task {
            var count = 0
            do {
                try writable(); guard offset >= 0, offset <= Int64.max - Int64(contents.count) else { throw POSIXError(.EINVAL) }; let nodeID = try id(item)
                // FSKit may deliver concurrent page-out writes for one vnode.
                // Keep the generation read/stage/commit sequence ordered, and
                // keep close from releasing the shared lease during a write.
                await handleGate.acquire(nodeID)
                do {
                while count < contents.count {
                    let end = min(contents.count, count + owner.preferredWriteSize)
                    var request = NamespaceRPCRequest(operation: "write", nodeID: nodeID, offset: offset + Int64(count), data: count == 0 && end == contents.count ? contents : contents.subdata(in: count..<end)); request.handleID = lock.withLock { handles[nodeID] }
                    let response = try await rpc(request)
                    if let node = response.node { _ = cached(node) }
                    count = end
                }
                await handleGate.release(nodeID)
                reply(count, nil)
                } catch { await handleGate.release(nodeID); throw error }
            } catch { reply(count, error) }
        }
    }
}
