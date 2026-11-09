import CryptoKit
import Foundation
import Darwin

public struct NamespaceEngineConfiguration: Codable, Sendable {
    public var directory: URL
    public var binding: String
    public var mode: NamespaceStorageMode
    public var storage: R2StorageConfiguration?
    public var fixtureDirectory: URL?
    public var resourceDirectory: URL?
    public var sessionID: UUID?
    public var readOnly: Bool
    public var restoreManaged: Bool?
    public var encryptionKeyBase64: String?
    public var encryptionKeyID: String?
    public var uploadRateBytesPerSecond: Int64?
    public init(directory: URL, binding: String, mode: NamespaceStorageMode = .compatible,
                storage: R2StorageConfiguration? = nil, fixtureDirectory: URL? = nil, resourceDirectory: URL? = nil, sessionID: UUID? = nil, readOnly: Bool = true, restoreManaged: Bool? = nil, encryptionKeyBase64: String? = nil, encryptionKeyID: String? = nil, uploadRateBytesPerSecond: Int64? = nil) {
        self.directory = directory; self.binding = binding; self.mode = mode
        self.storage = storage; self.fixtureDirectory = fixtureDirectory; self.resourceDirectory = resourceDirectory; self.readOnly = readOnly
        self.sessionID = sessionID; self.restoreManaged = restoreManaged
        self.encryptionKeyBase64 = encryptionKeyBase64; self.encryptionKeyID = encryptionKeyID; self.uploadRateBytesPerSecond = uploadRateBytesPerSecond
    }
}

/// Authoritative namespace, generation leases and mutation admission live in one owner.
/// UI, filesystem adapter, search and upload clients all use this same dispatcher.
public actor NamespaceOwner {
    public let store: NamespaceStore
    public let sync: SyncEngine
    private let directory: URL
    private let migration: NamespaceMigration?
    private let exporter: NamespaceExporter?
    private var readOnly: Bool
    private let uploadBandwidthLimiter: UploadBandwidthLimiter?
    private var uploadRateToRestore: Int64?
    private var configuredUploadRate: Int64?
    private var uploadRateUpdate: Task<Void, Error>?
    private struct ClientHandle {
        var node: NamespaceNode
        let retention: UUID
        let bufferedWrites: Bool
        let peer: NamespaceRPCPeer
    }
    private var handles: [UUID: ClientHandle] = [:]
    private var responses: [UUID: (digest: Data, response: NamespaceRPCResponse, bytes: Int)] = [:]
    private var responseOrder: [UUID] = []
    private var responseBytes = 0
    private var inFlight: [UUID: (digest: Data, peer: NamespaceRPCPeer, task: Task<NamespaceRPCResponse, Never>)] = [:]
    private var detached = true
    private var paused = false
    private var quiescing = false
    private var capacitySample: (time: ContinuousClock.Instant, bytes: Int64)?
    private var controlStateInvalid = false
    private struct ControlState: Codable { var version = 1; var paused: Bool; var uploadRateBytesPerSecond: Int64? = nil }
    public init(store: NamespaceStore, sync: SyncEngine, directory: URL, readOnly: Bool = true, migration: NamespaceMigration? = nil, exporter: NamespaceExporter? = nil, uploadBandwidthLimiter: UploadBandwidthLimiter? = nil) {
        self.store = store; self.sync = sync; self.directory = directory; self.readOnly = readOnly; self.migration = migration; self.exporter = exporter; self.uploadBandwidthLimiter = uploadBandwidthLimiter
        let control = directory.appendingPathComponent("sync-control.json")
        if FileManager.default.fileExists(atPath: control.path) {
            do {
                let state = try CoreFileIO.readChecked(ControlState.self, at: control, maximum: 4096)
                guard state.version == 1, state.uploadRateBytesPerSecond.map({ $0 >= 0 && $0 <= 1_099_511_627_776 }) ?? true else { throw StorageFailure.integrity }; paused = state.paused; uploadRateToRestore = state.uploadRateBytesPerSecond; configuredUploadRate = state.uploadRateBytesPerSecond
            } catch { paused = true; controlStateInvalid = true }
        }
    }
    public func handle(_ request: NamespaceRPCRequest) async -> NamespaceRPCResponse {
        var request = request
        // Public in-process calls are trusted code in this owner. Socket requests
        // always arrive with the authenticated kernel identity injected below.
        guard let peer = request.trustedPeer ?? (try? NamespaceRPCPeer.capture(pid: getpid())),
              peer.uid == getuid(), peer.matchesRunningProcess else {
            return .failure(request, error: POSIXError(.EPERM))
        }
        request.trustedPeer = peer
        await reapExitedClients()
        var identity = request; identity.authToken = nil
        let payload = identity.data
        guard (payload?.count ?? 0) <= NamespaceOwnerDescriptor.maximumWriteBytes else { return .failure(request, error: POSIXError(.EMSGSIZE)) }
        identity.data = nil
        struct ReplayIdentity: Encodable { let peer: NamespaceRPCPeer; let request: NamespaceRPCRequest; let payloadDigest: Data? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(ReplayIdentity(peer: peer, request: identity, payloadDigest: payload.map { Data(SHA256.hash(data: $0)) })), encoded.count <= 4_194_304 else {
            return .failure(request, error: POSIXError(.EMSGSIZE))
        }
        let fingerprint = Data(SHA256.hash(data: encoded))
        // Same request IDs are never admitted twice while a staging/remote await yields.
        if let existing = responses[request.requestID] {
            return existing.digest == fingerprint ? existing.response : .failure(request, error: POSIXError(.EPROTO))
        }
        if let existing = inFlight[request.requestID] {
            return existing.digest == fingerprint ? await existing.task.value : .failure(request, error: POSIXError(.EPROTO))
        }
        guard inFlight.count < 32 else { return .failure(request, error: POSIXError(.EBUSY)) }
        let task = Task { [request] in await self.execute(request) }
        inFlight[request.requestID] = (fingerprint, peer, task)
        let response = await task.value
        inFlight.removeValue(forKey: request.requestID)
        var metadata = response; metadata.data = nil
        let payloadSize = response.data?.count ?? 0
        let bytes = ((try? JSONEncoder().encode(metadata).count) ?? 0) + (payloadSize + 2) / 3 * 4 + fingerprint.count
        // Busy is an admission/retry outcome, not a durable result. Caching it
        // would keep an otherwise valid same-ID retry busy after capacity frees.
        if bytes <= 2_097_152 && response.error?.errno != EBUSY {
            responses[request.requestID] = (fingerprint, response, bytes); responseOrder.append(request.requestID); responseBytes += bytes
            while responseOrder.count > 256 || responseBytes > 8_388_608 {
                let id = responseOrder.removeFirst()
                if let old = responses.removeValue(forKey: id) { responseBytes -= old.bytes }
            }
        }
        return response
    }
    private func execute(_ request: NamespaceRPCRequest) async -> NamespaceRPCResponse {
        do {
            try await restoreUploadRate()
            var response = NamespaceRPCResponse(requestID: request.requestID)
            let mutations: Set<String> = ["create", "rename", "remove", "write", "truncate", "setattrs", "setxattr", "submitUpload", "trash", "restoreTrash", "purgeTrash"]
            guard !controlStateInvalid || !mutations.contains(request.operation) else { throw StorageFailure.integrity }
            guard !readOnly || !mutations.contains(request.operation) else { throw POSIXError(.EROFS) }
            let passive: Set<String> = ["volume", "node", "availability", "lookup", "list", "search", "path", "events", "importProgress", "exportProgress", "activity", "trashList", "status", "capacity", "close", "detach", "pause", "prepareStop"]
            guard !quiescing || passive.contains(request.operation) else { throw POSIXError(.EBUSY) }
            switch request.operation {
            case "volume": response.volume = try await store.volume()
            case "node": response.node = try await node(request)
            case "availability":
                let captured = try await node(request)
                var state = "unknown"
                if captured.stagedSnapshotID == nil, captured.kind != .file || captured.backing != nil {
                    let verified = try? await sync.cache.availability(nodes: [captured], maximumVerificationBytes: 1_048_576)
                    let current = try await node(request)
                    if current.contentGeneration == captured.contentGeneration, current.size == captured.size,
                       current.backing == captured.backing, current.stagedSnapshotID == nil {
                        state = verified?["availability:" + captured.id.uuidString] ?? "unknown"
                    }
                }
                response.attributes = ["availability": state]
            case "lookup":
                guard let parent = request.parentID, let name = request.name else { throw POSIXError(.EINVAL) }
                guard let found = try await store.lookup(parentID: parent, name: name) else { throw NamespaceFailure.notFound }
                response.node = found
            case "list":
                guard let parent = request.parentID ?? request.nodeID else { throw POSIXError(.EINVAL) }
                let page = try await store.list(parentID: parent, after: request.cookie, limit: min(1024, max(1, request.limit ?? 256)), includeDotInodes: request.attributes?["dotInodes"] == "true")
                response.nodes = page.nodes.map { $0.listingEntry() }; response.nextCookie = page.next; response.revision = page.revision
                if let dots = page.dotInodes {
                    response.attributes = ["directoryInode": String(dots.directory), "parentInode": String(dots.parent)]
                }
            case "search":
                let matches = try await store.searchNames(text: request.name ?? "", limit: min(1000, max(1, request.limit ?? 100)))
                response.nodes = matches.map { $0.listingEntry() }
                var paths: [String: String] = [:]
                for node in matches { paths[node.id.uuidString] = try await store.resolvedPath(node.id) }
                paths.merge(try await sync.cache.availability(nodes: matches)) { _, new in new }
                response.attributes = paths
            case "path":
                let value = try await node(request)
                response.attributes = ["path": try await store.resolvedPath(value.id)]
            case "create":
                guard let parent = request.parentID, let name = request.name, let kind = request.kind else { throw POSIXError(.EINVAL) }
                let attributes = request.attributes ?? [:]
                let nativeXattrs = attributes["xattrs"] == "native"
                guard Set(attributes.keys).isSubset(of: ["size", "xattrs"]), attributes["xattrs"] == nil || nativeXattrs, attributes["size"] == nil || attributes["size"].flatMap(Int64.init).map({ $0 >= 0 }) == true else { throw POSIXError(.EINVAL) }
                if let size = attributes["size"].flatMap(Int64.init), size > 0 {
                    guard kind == .file else { throw NamespaceFailure.isDirectory }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    var sparseIdentity = ["kind": "createSparse", "parent": parent.uuidString, "name": name, "size": String(size)]
                    if nativeXattrs { sparseIdentity["xattrs"] = "native" }
                    let fingerprint = CoreFileIO.hash(try encoder.encode(sparseIdentity))
                    if let prior = try await store.operation(request.requestID) {
                        guard prior.kind == .write, let accepted = prior.nodeSnapshot, accepted.parentID == parent, accepted.name == name,
                              accepted.size == size, let snapshotID = prior.stagedSnapshotID else { throw NamespaceFailure.invalidTransition }
                        let saved = try await store.receipts(operationID: prior.id).first { $0.stepID == "mutation-fingerprint" }?.validator
                        if let saved { guard saved == fingerprint else { throw NamespaceFailure.invalidTransition } }
                        else { guard try await sync.content.snapshot(id: snapshotID).mutationFingerprint == fingerprint else { throw NamespaceFailure.invalidTransition } }
                        response.node = accepted
                    } else {
                        let id = UUID()
                        let snapshot = try await sync.content.prepareTruncate(nodeID: id, fromGeneration: 0, toGeneration: 1,
                            logicalSize: 0, base: nil, size: size, mutationFingerprint: fingerprint)
                        response.node = try await store.createContent(parentID: parent, name: name, nodeID: id, snapshotID: snapshot.id, size: size, operationID: request.requestID, nativeXattrs: nativeXattrs)
                    }
                } else { response.node = try await store.create(parentID: parent, name: name, kind: kind, operationID: request.requestID, nativeXattrs: nativeXattrs) }
                if let node = response.node { try? await sync.noteNamespaceChange(nodeID: node.id) }
            case "submitUpload":
                guard let parent = request.parentID, let name = request.name, let data = request.data, data.count <= 65_536 else { throw POSIXError(.EINVAL) }
                let source = try JSONDecoder().decode(ResidentSourceIdentity.self, from: data)
                if let previous = try await store.operation(request.requestID) {
                    guard previous.kind == .write, let snapshot = previous.stagedSnapshotID,
                          previous.nodeSnapshot?.parentID == parent, previous.nodeSnapshot?.name == name,
                          try await sync.content.snapshot(id: snapshot).externalSource == source else { throw NamespaceFailure.invalidTransition }
                    response.node = try await store.retainedNode(previous.nodeID)
                } else {
                    response.node = try await sync.createFromSource(parentID: parent, name: name, source: source, operationID: request.requestID)
                }
            case "rename":
                guard let id = request.nodeID, let parent = request.destinationParentID, let name = request.destinationName else { throw POSIXError(.EINVAL) }
                _ = try await store.rename(nodeID: id, parentID: parent, name: name, replace: request.replace ?? false, operationID: request.requestID)
                response.node = try await store.node(id)
                await refreshHandles(id)
                try? await sync.noteNamespaceChange(nodeID: id)
            case "remove":
                guard let id = request.nodeID else { throw POSIXError(.EINVAL) }
                _ = try await store.remove(nodeID: id, operationID: request.requestID)
            case "trash":
                guard let id = request.nodeID else { throw POSIXError(.EINVAL) }
                response.data = try JSONEncoder().encode(try await store.moveToTrash(nodeID: id, operationID: request.requestID))
                await refreshHandles(id)
                try? await sync.noteNamespaceChange(nodeID: id)
            case "trashList":
                let page = try await store.trashEntries(after: request.cookie, limit: min(500, max(1, request.limit ?? 200)))
                response.data = try JSONEncoder().encode(page.entries); response.nextCookie = page.next
            case "purgeTrash":
                guard let id = request.nodeID else { throw POSIXError(.EINVAL) }
                _ = try await store.purgeTrash(containerID: id, operationID: request.requestID)
                response.attributes = ["removedFromRecentlyDeleted": "true"]
            case "restoreTrash":
                guard let id = request.nodeID else { throw POSIXError(.EINVAL) }
                response.node = try await store.restoreFromTrash(containerID: id, parentID: request.destinationParentID, name: request.destinationName, operationID: request.requestID)
                if let node = response.node { await refreshHandles(node.id); try? await sync.noteNamespaceChange(nodeID: node.id) }
            case "open":
                let value = try await node(request)
                guard handles.count < 65_536 else { throw POSIXError(.EMFILE) }
                let id = UUID(), retention = await sync.retain(node: value)
                guard let peer = request.trustedPeer else { await sync.release(token: retention); throw POSIXError(.EPERM) }
                let buffered = request.attributes?["bufferedWrites"] == "true" && request.attributes?["writable"] == "true"
                    && value.kind == .file && value.size == 0 && value.backing == nil && value.contentGeneration == 0
                handles[id] = ClientHandle(node: value, retention: retention, bufferedWrites: buffered, peer: peer); response.node = value; response.handleID = id; response.generation = value.contentGeneration
            case "close":
                guard let id = request.handleID, let handle = handles[id], handle.peer == request.trustedPeer,
                      request.nodeID == nil || request.nodeID == handle.node.id else { throw POSIXError(.EBADF) }
                if handle.bufferedWrites { try await store.sealOpenWrites() }
                handles.removeValue(forKey: id)
                await sync.release(token: handle.retention)
            case "read":
                guard let offset = request.offset, let length = request.length, offset >= 0, length >= 0, length <= 1_048_576 else { throw POSIXError(.EINVAL) }
                let value = try await node(request)
                response.data = try await sync.read(node: value, offset: offset, length: length)
                response.generation = value.contentGeneration
            case "write":
                guard let offset = request.offset, let data = request.data, offset >= 0, data.count <= NamespaceOwnerDescriptor.maximumWriteBytes else { throw POSIXError(.EINVAL) }
                let value = try await node(request)
                if let expected = request.generation, expected != value.contentGeneration { throw NamespaceFailure.generationChanged }
                let buffered = request.handleID.flatMap { handles[$0]?.bufferedWrites } == true
                let updated = try await sync.write(node: value, offset: offset, data: data, operationID: request.requestID, bufferedHandle: buffered)
                response.node = updated; await refreshHandles(updated.id, captured: updated)
            case "truncate":
                guard let size = request.offset, size >= 0 else { throw POSIXError(.EINVAL) }
                let value = try await node(request)
                let updated = try await sync.truncate(node: value, size: size, operationID: request.requestID)
                response.node = updated; await refreshHandles(updated.id, captured: updated)
            case "setxattr":
                guard let id = request.nodeID, let name = request.name, let policy = request.attributes?["policy"] else { throw POSIXError(.EINVAL) }
                let operation = try await store.setXattr(nodeID: id, name: name, value: request.data, policy: policy, operationID: request.requestID)
                response.node = operation.nodeSnapshot
            case "setattrs":
                let attributes = request.attributes ?? [:]
                guard Set(attributes.keys).isSubset(of: ["size", "modifiedAt"]) else { throw POSIXError(.ENOTSUP) }
                guard attributes["size"] == nil || attributes["size"].flatMap(Int64.init).map({ $0 >= 0 }) == true,
                      attributes["modifiedAt"] == nil || ISO8601DateFormatter().date(from: attributes["modifiedAt"]!) != nil else { throw POSIXError(.EINVAL) }
                let value = try await node(request)
                if let size = attributes["size"].flatMap(Int64.init) {
                    response.node = try await sync.truncate(nodeID: value.id, size: size); await refreshHandles(value.id)
                } else { response.node = value }
                if let text = attributes["modifiedAt"], let date = ISO8601DateFormatter().date(from: text) {
                    _ = try await store.updateMetadata(nodeID: value.id, modifiedAt: date, operationID: request.requestID)
                    response.node = try await store.node(value.id)
                }
            case "sync": try await sync.synchronize(waitForCloud: request.attributes?["waitForCloud"] == "true")
            case "pin":
                let value = try await node(request); try await sync.pin(nodeID: value.id, recursive: request.attributes?["recursive"] == "true")
            case "unpin":
                let value = try await node(request); try await sync.unpin(nodeID: value.id, recursive: request.attributes?["recursive"] == "true")
            case "freeLocalSpace":
                let value = try await node(request); try await sync.freeLocalSpace(nodeID: value.id, recursive: request.attributes?["recursive"] == "true")
            case "configureUploadRate":
                guard let rate = request.offset, rate >= 0, rate <= 1_099_511_627_776, let uploadBandwidthLimiter else { throw POSIXError(.EINVAL) }
                try CoreFileIO.atomicChecked(ControlState(paused: paused, uploadRateBytesPerSecond: rate), at: directory.appendingPathComponent("sync-control.json"))
                configuredUploadRate = rate
                try await enqueueUploadRate(rate, limiter: uploadBandwidthLimiter).value
            case "resume":
                try CoreFileIO.atomicChecked(ControlState(paused: false, uploadRateBytesPerSecond: configuredUploadRate), at: directory.appendingPathComponent("sync-control.json"))
                paused = false; controlStateInvalid = false
                Task { try? await sync.resume() }
                response.attributes = ["resumeRequested": "true"]
            case "pause":
                try CoreFileIO.atomicChecked(ControlState(paused: true, uploadRateBytesPerSecond: configuredUploadRate), at: directory.appendingPathComponent("sync-control.json"))
                paused = true; await sync.requestPause(); try await sync.synchronize(waitForCloud: false)
            case "attach":
                guard !quiescing else { throw POSIXError(.EBUSY) }; detached = false
            case "detach": try await store.sealOpenWrites(); detached = true
            case "prepareStop":
                try await store.sealOpenWrites()
                await reapExitedClients()
                let status = try await sync.status()
                guard detached, handles.isEmpty, inFlight.count == 1,
                      status.pending == 0, status.activeOperationID == nil,
                      ["idle", "paused"].contains(status.phase), status.requestedPins == status.completedPins, status.pinAttention == 0,
                      readOnly || status.publishedRevision == status.localRevision else { throw POSIXError(.EBUSY) }
                quiescing = true; paused = true
                response.attributes = ["safeToStop": "true"]
            case "enableWrites":
                // A read-only preview must be detached before changing its write admission.
                guard detached, handles.isEmpty else { throw POSIXError(.EBUSY) }; readOnly = false
            case "capacity":
                guard !controlStateInvalid else { throw StorageFailure.integrity }
            case "status":
                guard !controlStateInvalid else { throw StorageFailure.integrity }
                response.data = try JSONEncoder().encode(try await sync.status())
                response.volume = try await store.volume()
            case "activity":
                let items = try await store.activity(limit: min(500, max(1, request.limit ?? 200)))
                response.data = try JSONEncoder().encode(items)
                var nodes: [NamespaceNode] = []
                for id in Set(items.map(\.nodeID)) {
                    if let node = try? await store.node(id) { nodes.append(node) }
                }
                response.attributes = try await sync.cache.availability(nodes: nodes)
            case "pinStatus": response.data = try JSONEncoder().encode(try await sync.pinProgress())
            case "import":
                guard readOnly, detached, handles.isEmpty, let migration else { throw POSIXError(.EBUSY) }
                response.data = try JSONEncoder().encode(try await migration.importCompatible())
            case "importProgress":
                guard let migration else { throw POSIXError(.ENOTSUP) }
                response.data = try JSONEncoder().encode(try await migration.progress())
            case "qualifyStorage":
                guard let migration else { throw POSIXError(.ENOTSUP) }
                try await migration.qualifyCompatibility()
                response.attributes = ["conditionalDeletes": "qualified"]
            case "seedManaged":
                guard readOnly, detached, handles.isEmpty else { throw POSIXError(.EBUSY) }
                try await sync.publishInitialNamespace()
            case "export":
                guard let exporter, let destination = request.name else { throw POSIXError(.ENOTSUP) }
                response.data = try JSONEncoder().encode(try await exporter.export(to: destination))
            case "exportProgress":
                throw POSIXError(.ENOTSUP) // No fabricated progress for an unimplemented exporter query.
            case "events":
                let events = try await store.events(after: request.offset ?? 0, limit: min(1024, max(1, request.limit ?? 256)))
                response.data = try JSONEncoder().encode(events)
            default: throw POSIXError(.ENOTSUP)
            }
            var attributes = response.attributes ?? [:]
            // Finder asks for capacity separately. Keep the compatibility reply
            // attribute on ordinary calls without repeatedly walking the cache.
            if request.operation == "capacity" || request.operation == "status" || capacitySample.map({ $0.time.duration(to: .now) >= .seconds(1) }) != false {
                let space = Int64(try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0)
                let staging = await sync.content.accounting()
                capacitySample = (.now, await sync.finderAvailableBytes(localAvailable: space, staging: staging))
            }
            attributes["availableBytes"] = capacitySample.map { String($0.bytes) }
            if let uploadBandwidthLimiter { attributes["uploadRateBytesPerSecond"] = String(await uploadBandwidthLimiter.rateBytesPerSecond()) }
            attributes["readOnly"] = String(readOnly); attributes["pid"] = String(getpid())
            attributes["detached"] = String(detached); attributes["openHandles"] = String(handles.count)
            attributes["paused"] = String(paused); attributes["quiescing"] = String(quiescing); response.attributes = attributes
            return response
        } catch { return .failure(request, error: error) }
    }
    private func node(_ request: NamespaceRPCRequest) async throws -> NamespaceNode {
        if let id = request.handleID {
            guard let handle = handles[id], handle.peer == request.trustedPeer, request.nodeID == nil || request.nodeID == handle.node.id else { throw POSIXError(.EBADF) }
            return handle.node
        }
        guard let id = request.nodeID else { throw POSIXError(.EINVAL) }
        return try await store.node(id)
    }
    private func refreshHandles(_ id: UUID, captured: NamespaceNode? = nil) async {
        let loaded: NamespaceNode?
        if let current = try? await store.retainedNode(id) { loaded = current } else { loaded = captured }
        guard let current = loaded else { return }
        for key in Array(handles.keys) where handles[key]?.node.id == id {
            if let old = handles[key] {
                if await sync.refreshRetention(token: old.retention, node: current),
                   let latest = handles[key], latest.retention == old.retention,
                   latest.node.contentGeneration <= current.contentGeneration, latest.node.metadataGeneration <= current.metadataGeneration {
                    handles[key] = ClientHandle(node: current, retention: old.retention, bufferedWrites: old.bufferedWrites, peer: old.peer)
                }
            }
        }
    }
    /// Retire only a proven exited process incarnation, and only after all its
    /// accepted in-flight requests finish. Inspection failure retains every lease.
    public func reapExitedClients() async {
        let busyPeers = Set(inFlight.values.map(\.peer))
        let exited = Set(handles.values.map(\.peer)).filter { !busyPeers.contains($0) && $0.hasDefinitelyExited }
        for peer in exited {
            for id in Array(handles.keys) where handles[id]?.peer == peer {
                guard let handle = handles[id] else { continue }
                if handle.bufferedWrites { do { try await store.sealOpenWrites() } catch { continue } }
                handles.removeValue(forKey: id)
                await sync.release(token: handle.retention)
            }
        }
    }
    private func enqueueUploadRate(_ rate: Int64, limiter: UploadBandwidthLimiter) -> Task<Void, Error> {
        let previous = uploadRateUpdate
        let update = Task {
            if let previous { try await previous.value }
            try await limiter.setRate(bytesPerSecond: rate)
        }
        uploadRateUpdate = update
        return update
    }
    private func restoreUploadRate() async throws {
        if let rate = uploadRateToRestore, let uploadBandwidthLimiter {
            // Clear before yielding and share one ordered update task. Concurrent
            // RPC/background calls cannot replay an old restored rate after a new
            // configuration has been durably accepted.
            uploadRateToRestore = nil
            _ = enqueueUploadRate(rate, limiter: uploadBandwidthLimiter)
        }
        if let update = uploadRateUpdate { try await update.value }
        if configuredUploadRate == nil, let uploadBandwidthLimiter {
            let initial = await uploadBandwidthLimiter.rateBytesPerSecond()
            if configuredUploadRate == nil { configuredUploadRate = initial }
        }
    }
    public func backgroundStep() async {
        do { try await EngineTrace.measure("bg.sealIdleOpenWrites") { try await store.sealIdleOpenWrites() } } catch { return }
        do { try await restoreUploadRate() } catch { controlStateInvalid = true; return }
        await EngineTrace.measure("bg.reapExitedClients") { await reapExitedClients() }
        if paused { await sync.requestPause(); return }
        try? await EngineTrace.measure("bg.processPending") { try await sync.processPending(limit: 128, waitForQuiet: true) }
    }
    public func backgroundPayloadStep() async {
        guard !paused, !controlStateInvalid, !quiescing else { return }
        do { try await restoreUploadRate() } catch { controlStateInvalid = true; return }
        guard !paused, !quiescing else { return }
        await EngineTrace.measure("bg.prepareAhead") { await sync.prepareManagedPayloadsAhead() }
    }
    public func canStop() async -> Bool {
        await reapExitedClients()
        guard detached, handles.isEmpty, inFlight.isEmpty else { return false }
        let empty = (try? await store.operations(limit: 1).isEmpty) == true
        return empty && detached && handles.isEmpty && inFlight.isEmpty
    }
}
