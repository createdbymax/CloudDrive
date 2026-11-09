import Foundation
import CryptoKit
import Darwin

public struct ContentExtent: Codable, Equatable, Sendable {
    public var offset: Int64
    public var length: Int64
    public var fileID: UUID
    public var storedLength: Int64
    public var fileOffset: Int64? = nil
    public var checksum: String
}
public struct ContentSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var nodeID: NodeID
    public var generation: Int64
    public var size: Int64
    public var base: ObjectLocator?
    public var baseReadableSize: Int64
    public var extentRoot: Int64? = nil
    public var extents: [ContentExtent]
    public var externalSource: ResidentSourceIdentity? = nil
    public var mutationFingerprint: String? = nil
}
public struct ContentAccounting: Codable, Equatable, Sendable {
    public var dirtyBytes: Int64
    public var snapshotCount: Int
    public var maximumBytes: Int64
    public var retainedCleanBytes: Int64 = 0
}

/// Immutable write extents are flushed before a snapshot manifest is published.
/// The namespace then records the manifest ID in its own durable transaction.
/// Failure between these boundaries can leave an orphan; it cannot acknowledge
/// namespace bytes that have not been saved. Orphans are retained until explicit GC.
public actor ContentStore {
    public let directory: URL
    private let maximumBytes: Int64
    private struct PackedMember: Codable {
        let id: UUID
        let offset: Int64
        let length: Int64
        let checksum: String
    }
    private struct CloudExtent: Codable {
        let id: UUID
        let prefix: String
        let checksum: String
        let length: Int64
        var validator: String?
        var members: [PackedMember]?
        var key: String { prefix + "/.clouddrive/v1/writeback/" + id.uuidString + "/" + checksum }
    }
    private var cloudExtents: [UUID: CloudExtent] = [:]
    private let verifiedCloudObjects: VerifiedCloudObjectCache
    private var packedMembers: [UUID: (objectID: UUID, member: PackedMember)] = [:]
    private var spillCandidates: ArraySlice<ContentExtent> = []
    private var packing: [UUID: Task<Void, Never>] = [:]
    private var packingWaiters: [CheckedContinuation<Void, Never>] = []
    private var packingRefillsPending = 0
    private var packingFailure: Error?
    private var selectedPackingBytes: Int64 = 0
    private let maximumPackingJobs: Int
    private let maximumWritebackWindow: Int64
    private static let maximumPackBytes: Int64 = 8 * 1024 * 1024
    private var activeCloudExtents: Set<UUID> = []
    private let index: ManagedExtentIndex
    private var groupLocalWriteBarriers: Bool
    private var testOverrideBarrier = false
    private var mediaBarrier: (Int32) throws -> Void = CoreFileIO.requireMediaBarrier
    #if DEBUG
    func configureWriteBarrierForTesting(enabled: Bool, barrier: @escaping (Int32) throws -> Void = CoreFileIO.requireMediaBarrier) {
        groupLocalWriteBarriers = enabled && CoreFileIO.sameAPFSVolume(directory.appendingPathComponent("extents"), directory.appendingPathComponent("snapshots"))
        testOverrideBarrier = true
        mediaBarrier = barrier
    }
    #endif
    private var readingCloudExtents: [UUID: Int] = [:]
    private var owner: Int32 = -1
    private let identities: [CoreDirectoryIdentity]
    private var used: Int64
    private var manifests: [UUID: ContentSnapshot] = [:]
    private var aliases: [String: ObjectLocator] = [:]
    private var publishedExtents: Set<UUID> = []
    private var allocated: [UUID: Int64] = [:]
    private var discardedSnapshots: Set<UUID> = []

    public init(directory: URL, maximumBytes: Int64 = 20 * 1024 * 1024 * 1024,
                writebackWindow: Int64 = 256 * 1024 * 1024, packingJobs: Int = 4) throws {
        guard maximumBytes > 0, writebackWindow > 0 else { throw StorageFailure.localStorageFull }
        let normalizedDirectory = directory.standardizedFileURL
        try CoreFileIO.privateDirectory(normalizedDirectory)
        self.directory = normalizedDirectory
        self.maximumBytes = maximumBytes
        maximumWritebackWindow = min(maximumBytes, writebackWindow)
        maximumPackingJobs = min(20, max(1, packingJobs))
        verifiedCloudObjects = VerifiedCloudObjectCache(directory: directory.appendingPathComponent("verified-cloud-cache"),
                                                        maximumFetches: max(8, maximumPackingJobs + 4))
        try CoreFileIO.privateDirectory(self.directory)
        try CoreFileIO.privateDirectory(self.directory.appendingPathComponent("extents"))
        try CoreFileIO.privateDirectory(self.directory.appendingPathComponent("snapshots"))
        try CoreFileIO.privateDirectory(self.directory.appendingPathComponent("responses"))
        try CoreFileIO.privateDirectory(self.directory.appendingPathComponent("writeback"))
        identities = try [self.directory.appendingPathComponent("writeback"), self.directory, self.directory.appendingPathComponent("extents"), self.directory.appendingPathComponent("snapshots"), self.directory.appendingPathComponent("responses")].map(CoreDirectoryIdentity.init)
        groupLocalWriteBarriers = CoreFileIO.sameAPFSVolume(self.directory.appendingPathComponent("extents"), self.directory.appendingPathComponent("snapshots"))
        owner = try CoreFileIO.lock(self.directory.appendingPathComponent("owner.lock"))
        do { index = try ManagedExtentIndex(self.directory) } catch { close(owner); owner = -1; throw error }
        var total: Int64 = 0
        do {
            let discardedURL = self.directory.appendingPathComponent("discarded-snapshots.json")
            if FileManager.default.fileExists(atPath: discardedURL.path) {
                discardedSnapshots = try CoreFileIO.readChecked(Set<UUID>.self, at: discardedURL, maximum: 64 * 1024 * 1024)
                for id in discardedSnapshots {
                    let manifest = self.directory.appendingPathComponent("snapshots/" + id.uuidString + ".json")
                    if FileManager.default.fileExists(atPath: manifest.path) { try CoreFileIO.remove(manifest) }
                }
            }
            for file in try FileManager.default.contentsOfDirectory(at: self.directory.appendingPathComponent("extents"), includingPropertiesForKeys: nil) {
                guard UUID(uuidString: file.lastPathComponent) != nil else { continue }
                _ = try CoreFileIO.regularSize(file)
                let addition = total.addingReportingOverflow(try CoreFileIO.allocatedSize(file))
                guard !addition.overflow else { throw StorageFailure.integrity }
                total = addition.partialValue
                if let id = UUID(uuidString: file.lastPathComponent) { allocated[id] = try CoreFileIO.allocatedSize(file) }
            }
            for file in try FileManager.default.contentsOfDirectory(at: self.directory.appendingPathComponent("writeback"), includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let record = try CoreFileIO.readChecked(CloudExtent.self, at: file, maximum: 128 * 1024)
                guard file.lastPathComponent == record.id.uuidString + ".json", (1...8 * 1024 * 1024).contains(record.length),
                      record.checksum.utf8.count == 64, record.checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      !record.prefix.isEmpty, record.validator?.isEmpty != true else { throw StorageFailure.integrity }
                if let members = record.members {
                    var end: Int64 = 0
                    guard !members.isEmpty, members.count <= 256 else { throw StorageFailure.integrity }
                    for member in members {
                        guard member.offset == end, member.length > 0, member.length <= record.length - end,
                              member.checksum.utf8.count == 64 else { throw StorageFailure.integrity }
                        end += member.length
                        if record.validator != nil {
                            guard packedMembers[member.id] == nil else { throw StorageFailure.integrity }
                            packedMembers[member.id] = (record.id, member)
                        }
                    }
                    guard end == record.length else { throw StorageFailure.integrity }
                }
                cloudExtents[record.id] = record
            }
            var localCandidates: [UUID: ContentExtent] = [:]
            for file in try FileManager.default.contentsOfDirectory(at: self.directory.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil) {
                guard file.pathExtension == "json" else { continue }
                let snapshot = try CoreFileIO.readChecked(ContentSnapshot.self, at: file, maximum: 16 * 1024 * 1024, allowedVersions: 1...2)
                guard snapshot.size >= 0, snapshot.generation >= 0,
                      snapshot.baseReadableSize >= 0, snapshot.baseReadableSize <= snapshot.size,
                      file.deletingPathExtension().lastPathComponent == snapshot.id.uuidString,
                      snapshot.extents.count <= 65536 else { throw StorageFailure.integrity }
                for extent in snapshot.extents {
                    guard extent.offset >= 0, extent.length > 0,
                          extent.offset <= Int64.max - extent.length, (extent.fileOffset ?? 0) >= 0,
                          (extent.fileOffset ?? 0) <= extent.storedLength - extent.length,
                          extent.length <= extent.storedLength else { throw StorageFailure.integrity }
                    if let packed = packedMembers[extent.fileID] {
                        guard packed.member.length == extent.storedLength, packed.member.checksum == extent.checksum else { throw StorageFailure.integrity }
                    } else if let cloud = cloudExtents[extent.fileID] {
                        guard cloud.validator != nil, cloud.length == extent.storedLength, cloud.checksum == extent.checksum else { throw StorageFailure.integrity }
                    } else {
                        guard try CoreFileIO.regularSize(self.directory.appendingPathComponent("extents/" + extent.fileID.uuidString)) == extent.storedLength else { throw StorageFailure.integrity }
                        localCandidates[extent.fileID] = extent
                    }
                }
                manifests[snapshot.id] = snapshot
            }
            let localIDs = Set(allocated.keys).subtracting(packedMembers.keys)
            let reachable = try index.reachable(Set(manifests.values.compactMap(\.extentRoot)), visit: { extents in
                for extent in extents where localIDs.contains(extent.fileID) { localCandidates[extent.fileID] = extent }
            })
            spillCandidates = ArraySlice(localCandidates.values.sorted(by: { $0.offset < $1.offset }))
            for id in reachable.extents {
                if allocated[id] == nil, packedMembers[id] == nil { guard cloudExtents[id]?.validator != nil else { throw StorageFailure.integrity } }
            }
        } catch { index.close(); close(owner); owner = -1; throw error }
        let aliasesURL = self.directory.appendingPathComponent("locator-aliases.json")
        if FileManager.default.fileExists(atPath: aliasesURL.path) {
            do { aliases = try CoreFileIO.readChecked([String: ObjectLocator].self, at: aliasesURL, maximum: 128 * 1024 * 1024) }
            catch { index.close(); close(owner); owner = -1; throw error }
        }
        let proofURL = self.directory.appendingPathComponent("published-extents.json")
        if FileManager.default.fileExists(atPath: proofURL.path) {
            do { publishedExtents = try CoreFileIO.readChecked(Set<UUID>.self, at: proofURL, maximum: 64 * 1024 * 1024) }
            catch { index.close(); close(owner); owner = -1; throw error }
        }
        used = total
    }
    deinit { index.close(); if owner >= 0 { close(owner) } }

    private func validate() throws { for identity in identities { try identity.validate() }; try CoreFileIO.validateLock(owner, at: directory.appendingPathComponent("owner.lock")) }
    private struct NoopResponse: Codable { var id: UUID; var fingerprint: String; var node: NamespaceNode }
    func noopResponse(id: UUID, fingerprint: String, nodeID: UUID) throws -> NamespaceNode? {
        try validate()
        let file = directory.appendingPathComponent("responses/" + id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let response = try CoreFileIO.readChecked(NoopResponse.self, at: file, maximum: 64 * 1024)
        guard response.id == id, response.fingerprint == fingerprint, response.node.id == nodeID else { throw NamespaceFailure.invalidTransition }
        return response.node
    }
    func recordNoopResponse(id: UUID, fingerprint: String, node: NamespaceNode) throws {
        try validate()
        if try noopResponse(id: id, fingerprint: fingerprint, nodeID: node.id) != nil { return }
        try CoreFileIO.atomicChecked(NoopResponse(id: id, fingerprint: fingerprint, node: node), at: directory.appendingPathComponent("responses/" + id.uuidString + ".json"))
    }
    private func locatorID(_ locator: ObjectLocator) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var identity = locator; identity.checksum = nil
        return CoreFileIO.hash(try encoder.encode(identity))
    }
    public func resolve(_ locator: ObjectLocator) throws -> ObjectLocator {
        try validate()
        var current = locator, seen = Set<String>()
        for _ in 0..<128 {
            let id = try locatorID(current)
            guard seen.insert(id).inserted else { throw StorageFailure.integrity }
            guard let next = aliases[id] else { return current }
            guard next.size == current.size else { throw StorageFailure.integrity }
            current = next
        }
        throw StorageFailure.integrity
    }
    /// Install only after the executor verifies the complete copy barrier. Readers
    /// of retained generations resolve old immutable locators through these durable
    /// aliases before source reclamation; their visible node identity never changes.
    public func recordVerifiedRelocation(source: ObjectLocator, destination: ObjectLocator) throws {
        try recordVerifiedRelocations([(source, destination)])
    }
    public func recordVerifiedRelocations(_ pairs: [(ObjectLocator, ObjectLocator)]) throws {
        try validate()
        guard pairs.count <= 100_000 else { throw StorageFailure.integrity }
        var changed = [String: ObjectLocator?]()
        do {
            // The executor has verified every destination against the live remote.
            // Returning to an earlier path may reproduce its previous validator
            // (e.g. content-based ETags). That identity is now a terminal again,
            // not the obsolete forwarding alias from its earlier relocation.
            for (_, destination) in pairs {
                let id = try locatorID(destination)
                if changed[id] == nil { changed[id] = .some(aliases[id]) }
                aliases.removeValue(forKey: id)
            }
            for (source, destination) in pairs {
                guard source.size == destination.size, source.validator != nil, destination.validator != nil,
                      (source.key != destination.key || source.validator != destination.validator) else {
                    if source.key == destination.key && source.validator == destination.validator && source.size == destination.size { continue }
                    throw StorageFailure.integrity
                }
                let target = try resolve(destination)
                guard try locatorID(target) != locatorID(source) else { throw StorageFailure.integrity }
                let id = try locatorID(source)
                if changed[id] == nil { changed[id] = .some(aliases[id]) }
                aliases[id] = destination
                _ = try resolve(source)
            }
            // Compact durable chains at each copy barrier. Repeated renames must
            // not become unreadable after the bounded resolver depth on restart.
            var compressed: [String: ObjectLocator] = [:]
            for (id, target) in aliases { compressed[id] = try resolve(target) }
            for (id, target) in compressed where aliases[id] != target {
                if changed[id] == nil { changed[id] = .some(aliases[id]) }
                aliases[id] = target
            }
            let data = try JSONEncoder().encode(aliases)
            guard data.count <= 128 * 1024 * 1024 else { throw StorageFailure.localStorageFull }
            try CoreFileIO.atomicChecked(aliases, at: directory.appendingPathComponent("locator-aliases.json"))
        } catch {
            for (id, previous) in changed { aliases[id] = previous }
            throw error
        }
    }
    public func accounting() -> ContentAccounting {
        let clean = allocated.filter { publishedExtents.contains($0.key) }.values.reduce(0, +)
        return .init(dirtyBytes: used - clean, snapshotCount: manifests.count, maximumBytes: maximumBytes, retainedCleanBytes: clean)
    }
    public func snapshot(id: UUID) throws -> ContentSnapshot {
        try validate()
        guard let snapshot = manifests[id] else { throw StorageFailure.notFound }
        return snapshot
    }
    public func latest(nodeID: NodeID, generation: Int64) throws -> ContentSnapshot? {
        try validate()
        let matches = manifests.values.filter { $0.nodeID == nodeID && $0.generation == generation }
        guard matches.count <= 1 else { throw StorageFailure.integrity }
        return matches.first
    }
    public func prepareWrite(nodeID: NodeID, fromGeneration: Int64, toGeneration: Int64,
                             logicalSize: Int64, base: ObjectLocator?, previousSnapshotID: UUID? = nil, offset: Int64, data: Data, mutationFingerprint: String? = nil) throws -> ContentSnapshot {
        try prepareWrite(nodeID: nodeID, fromGeneration: fromGeneration, toGeneration: toGeneration, logicalSize: logicalSize,
                         base: base, previousSnapshotID: previousSnapshotID, offset: offset, data: data, mutationFingerprint: mutationFingerprint, cloud: nil, indexed: false)
    }

    func prepareManagedWrite(nodeID: NodeID, fromGeneration: Int64, toGeneration: Int64, logicalSize: Int64, base: ObjectLocator?,
                             previousSnapshotID: UUID?, offset: Int64, data: Data, mutationFingerprint: String?, prefix: String,
                             remote: any StorageRemote, payloadChecksum: String? = nil, orderedByNamespace: Bool = false) async throws -> ContentSnapshot {
        try validate()
        guard offset >= 0, logicalSize >= 0, !data.isEmpty, data.count <= 8 * 1024 * 1024,
              offset <= Int64.max - Int64(data.count) else { throw StorageFailure.invalidRange }
        var available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        var window = min(maximumWritebackWindow, Int64(available) / 4)
        let reservation = try CoreFileIO.reservation(Int64(data.count))
        if reservation <= window, Int64(available) >= Int64(data.count) + 16 * 1024 * 1024 {
            while used > window - reservation {
                if let error = packingFailure { packingFailure = nil; throw error }
                try startPacking(prefix: prefix, remote: remote, allowPartial: true)
                guard !packing.isEmpty else { break }
                // Any verified pack can release admission space. A slow first
                // request must not hold up completed sibling packs.
                await withCheckedContinuation { packingWaiters.append($0) }
                try Task.checkCancellation(); try validate()
                available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
                window = min(maximumWritebackWindow, Int64(available) / 4)
                guard reservation <= window, Int64(available) >= Int64(data.count) + 16 * 1024 * 1024 else { break }
            }
            if reservation <= window, Int64(available) >= Int64(data.count) + 16 * 1024 * 1024, used <= window - reservation {
                let snapshot = try prepareWrite(nodeID: nodeID, fromGeneration: fromGeneration, toGeneration: toGeneration, logicalSize: logicalSize,
                    base: base, previousSnapshotID: previousSnapshotID, offset: offset, data: data, mutationFingerprint: mutationFingerprint, cloud: nil, indexed: true, payloadChecksum: payloadChecksum, orderedByNamespace: orderedByNamespace)
                // Start uploading older acknowledged extents while Finder fills the rest of the window.
                if packingFailure == nil, used >= max(8 * 1024 * 1024, window / 2) {
                    do { try startPacking(prefix: prefix, remote: remote, allowPartial: false) }
                    catch { packingFailure = error }
                }
                return snapshot
            }
        }
        let id = UUID()
        var record = CloudExtent(id: id, prefix: prefix, checksum: payloadChecksum ?? CoreFileIO.hash(data), length: Int64(data.count))
        activeCloudExtents.insert(id)
        defer { activeCloudExtents.remove(id) }
        record = try await uploadWriteback(record, bytes: data, remote: remote)
        return try prepareWrite(nodeID: nodeID, fromGeneration: fromGeneration, toGeneration: toGeneration, logicalSize: logicalSize,
                                base: base, previousSnapshotID: previousSnapshotID, offset: offset, data: data, mutationFingerprint: mutationFingerprint, cloud: record, indexed: true)
    }
    private struct PackSelection {
        let record: CloudExtent
        let bytes: Data
        let selected: [ContentExtent]
    }
    /// Reserve disjoint members synchronously, before a job can suspend on IO.
    /// Background batches wait for 8 MiB, 256 members, or a full next-extent
    /// boundary. Pressure may flush a partial pack to admit the next local write.
    private func selectPack(prefix: String, allowPartial: Bool) throws -> PackSelection? {
        try validate()
        var bytes = Data(), members: [PackedMember] = [], selected: [ContentExtent] = []
        while let first = spillCandidates.first, allocated[first.fileID] == nil || packedMembers[first.fileID] != nil { spillCandidates.removeFirst() }
        var full = false, selectedLength: Int64 = 0
        for next in spillCandidates.prefix(256) {
            guard allocated[next.fileID] != nil, packedMembers[next.fileID] == nil else { break }
            guard next.storedLength <= Self.maximumPackBytes - selectedLength else { full = true; break }
            selected.append(next); selectedLength += next.storedLength
            if selected.count == 256 || selectedLength == Self.maximumPackBytes { full = true; break }
        }
        guard !selected.isEmpty, allowPartial || full else { return nil }
        for next in selected {
            let payload = try CoreFileIO.read(directory.appendingPathComponent("extents/" + next.fileID.uuidString), maximum: 8 * 1024 * 1024)
            guard payload.count == next.storedLength, CoreFileIO.hash(payload) == next.checksum else { throw StorageFailure.integrity }
            members.append(PackedMember(id: next.fileID, offset: Int64(bytes.count), length: next.storedLength, checksum: next.checksum))
            bytes.append(payload)
        }
        spillCandidates.removeFirst(selected.count)
        let record = CloudExtent(id: UUID(), prefix: prefix, checksum: CoreFileIO.hash(bytes), length: Int64(bytes.count), members: members)
        activeCloudExtents.insert(record.id)
        for member in members { readingCloudExtents[member.id, default: 0] += 1 }
        selectedPackingBytes += record.length
        return PackSelection(record: record, bytes: bytes, selected: selected)
    }
    private func startPacking(prefix: String, remote: any StorageRemote, allowPartial: Bool) throws {
        while packing.count < maximumPackingJobs,
              let selection = try selectPack(prefix: prefix, allowPartial: allowPartial) {
            let id = selection.record.id
            packing[id] = Task {
                var failure: Error?
                do { try await self.pack(selection, remote: remote) }
                catch { failure = error }
                self.finishPacking(selection, remote: remote, failure: failure)
            }
        }
    }
    private func pack(_ selection: PackSelection, remote: any StorageRemote) async throws {
        let record = selection.record, members = record.members ?? []
        do {
            _ = try await uploadWriteback(record, bytes: selection.bytes, remote: remote)
        } catch {
            let retry = selection.selected.filter { allocated[$0.fileID] != nil && packedMembers[$0.fileID] == nil }
            spillCandidates = ArraySlice(retry) + spillCandidates
            throw error
        }
        for member in members {
            packedMembers[member.id] = (record.id, member)
        }
        // The verified, fully synced group receipt now resolves every member, even
        // if a crash interrupts unlinking these redundant local files.
        for member in members {
            if let size = allocated[member.id] {
                try CoreFileIO.remove(directory.appendingPathComponent("extents/" + member.id.uuidString))
                allocated.removeValue(forKey: member.id)
                used -= size
            }
        }
    }
    private func finishPacking(_ selection: PackSelection, remote: any StorageRemote, failure: Error?) {
        let record = selection.record
        packing.removeValue(forKey: record.id); activeCloudExtents.remove(record.id)
        selectedPackingBytes -= record.length
        for member in record.members ?? [] {
            if readingCloudExtents[member.id] == 1 { readingCloudExtents.removeValue(forKey: member.id) }
            else { readingCloudExtents[member.id, default: 1] -= 1 }
        }
        if let failure { packingFailure = failure }
        let waiters = packingWaiters; packingWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard packingFailure == nil else { return }
        // Queue refill after this actor job unwinds so its selected payload is
        // released before a replacement pack is assembled. Capture no selection.
        let prefix = record.prefix
        packingRefillsPending += 1
        Task { [weak self] in await self?.refillPacking(prefix: prefix, remote: remote) }
    }
    private func refillPacking(prefix: String, remote: any StorageRemote) {
        defer { packingRefillsPending -= 1 }
        guard packingFailure == nil, packing.count < maximumPackingJobs else { return }
        do {
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            let window = min(maximumWritebackWindow, Int64(available) / 4)
            if used >= max(Self.maximumPackBytes, window / 2) {
                try startPacking(prefix: prefix, remote: remote, allowPartial: false)
            }
        } catch { packingFailure = error }
    }
    #if DEBUG
    func packingStatusForTesting() -> (active: Int, selectedBytes: Int64, queued: Int, failed: Bool, pendingRefills: Int) {
        (packing.count, selectedPackingBytes, spillCandidates.count, packingFailure != nil, packingRefillsPending)
    }
    #endif
    private func uploadWriteback(_ intent: CloudExtent, bytes data: Data, remote: any StorageRemote) async throws -> CloudExtent {
        var record = intent
        let id = record.id
        let path = cloudRecordPath(id)
        // A lost response or process exit leaves the exact private key attributable.
        try CoreFileIO.atomicChecked(record, at: path)
        cloudExtents[id] = record
        let object: StorageObject
        do { object = try await remote.put(key: record.key, data: data, condition: .absent, operationID: id) }
        catch {
            guard let existing = try await remote.head(key: record.key) else { throw error }
            object = existing
        }
        guard object.key == record.key, object.operationID == id, object.size == record.length, !object.validator.isEmpty else { throw StorageFailure.integrity }
        record.validator = object.validator
        _ = try await verifiedBytes(record, remote: remote)
        try validate()
        try CoreFileIO.atomicChecked(record, at: path)
        cloudExtents[id] = record
        return record
    }
    private func cloudRecordPath(_ id: UUID) -> URL { directory.appendingPathComponent("writeback/" + id.uuidString + ".json") }
    private func verifiedBytes(_ record: CloudExtent, remote: any StorageRemote) async throws -> Data {
        guard let tag = record.validator else { throw StorageFailure.integrity }
        return try await verifiedCloudObjects.read(key: record.key, size: record.length, validator: tag,
                                                   checksum: record.checksum, remote: remote)
    }
    private func prepareWrite(nodeID: NodeID, fromGeneration: Int64, toGeneration: Int64, logicalSize: Int64, base: ObjectLocator?,
                              previousSnapshotID: UUID?, offset: Int64, data: Data, mutationFingerprint: String?, cloud: CloudExtent?, indexed: Bool, payloadChecksum: String? = nil, orderedByNamespace: Bool = false) throws -> ContentSnapshot {
        guard fromGeneration >= 0, fromGeneration < Int64.max, toGeneration == fromGeneration + 1, logicalSize >= 0,
              offset >= 0, offset <= Int64.max - Int64(data.count), data.count <= 8 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        let previous = try previousSnapshotID.map { try self.snapshot(id: $0) } ?? latest(nodeID: nodeID, generation: fromGeneration)
        guard previous == nil || (previous!.nodeID == nodeID && previous!.generation == fromGeneration && previous!.size == logicalSize) else { throw StorageFailure.integrity }
        var snapshot = ContentSnapshot(id: UUID(), nodeID: nodeID, generation: toGeneration,
                                       size: data.isEmpty ? logicalSize : max(logicalSize, offset + Int64(data.count)),
                                       base: previous?.base ?? base,
                                       baseReadableSize: previous?.baseReadableSize ?? min(base?.size ?? 0, logicalSize),
                                       extents: previous?.extents ?? [])
        snapshot.extentRoot = previous?.extentRoot
        snapshot.externalSource = previous?.externalSource
        snapshot.mutationFingerprint = mutationFingerprint
        var extentAwaitingBarrier: URL?
        if !data.isEmpty {
            // A replacement may split an old extent in two. Check the final
            // manifest count before writing payload; checking only the input count
            // could acknowledge a snapshot that startup refuses to load.
            let range = offset..<(offset + Int64(data.count))
            let fileID = cloud?.id ?? UUID()
            if cloud == nil {
                guard used <= maximumBytes - (try CoreFileIO.reservation(Int64(data.count))) else { throw StorageFailure.localStorageFull }
                let resource = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                if let available = resource.volumeAvailableCapacity, Int64(available) < Int64(data.count) + 16 * 1024 * 1024 { throw StorageFailure.localStorageFull }
                let extentURL = directory.appendingPathComponent("extents/" + fileID.uuidString)
                if indexed && groupLocalWriteBarriers {
                    // atomic() also fsyncs the parent after installing the extent.
                    // Its name and bytes are now queued for the same-device barrier.
                    try CoreFileIO.atomic(data, at: extentURL, syncFile: CoreFileIO.syncToDevice)
                    extentAwaitingBarrier = extentURL
                } else {
                    try CoreFileIO.atomic(data, at: extentURL)
                }
                let physical = try CoreFileIO.allocatedSize(directory.appendingPathComponent("extents/" + fileID.uuidString))
                used += physical; allocated[fileID] = physical
            }
            let added = ContentExtent(offset: offset, length: Int64(data.count), fileID: fileID, storedLength: Int64(data.count), checksum: cloud?.checksum ?? payloadChecksum ?? CoreFileIO.hash(data))
            if indexed && cloud == nil { spillCandidates.append(added) }
            if indexed, offset >= logicalSize, snapshot.extentRoot != nil, snapshot.extents.count < 32 {
                // Keep a bounded, disjoint append tail in the durable snapshot.
                // A sequential Finder copy then updates its extent tree once per
                // 32 chunks. Older readers reject these v2 checked manifests.
                snapshot.extents.append(added)
            } else if snapshot.extentRoot != nil {
                snapshot.extentRoot = try index.replace(root: snapshot.extentRoot, folding: snapshot.extents, range: range, extent: added)
                snapshot.extents = []
            } else if indexed && snapshot.extents.count >= 32 {
                let root = try index.build(extents: snapshot.extents)
                if offset >= logicalSize {
                    snapshot.extentRoot = root
                    snapshot.extents = [added]
                } else {
                    snapshot.extentRoot = try index.replace(root: root, range: range, extent: added)
                    snapshot.extents = []
                }
            } else {
                snapshot.extents = try Self.extentsAfterReplacing(snapshot.extents, range: range)
                snapshot.extents.append(added)
            }
        }
        try persist(snapshot, afterLocalExtent: extentAwaitingBarrier, orderedByNamespace: orderedByNamespace && !testOverrideBarrier)
        return snapshot
    }
    static func extentsAfterReplacing(_ extents: [ContentExtent], range: Range<Int64>) throws -> [ContentExtent] {
        var result: [ContentExtent] = []
        result.reserveCapacity(min(65536, extents.count + 1))
        for old in extents {
            let oldEnd = old.offset + old.length
            if old.offset >= range.upperBound || range.lowerBound >= oldEnd { result.append(old) }
            else {
                if old.offset < range.lowerBound { var before = old; before.length = range.lowerBound - old.offset; result.append(before) }
                if range.upperBound < oldEnd {
                    var after = old; after.offset = range.upperBound; after.length = oldEnd - range.upperBound
                    after.fileOffset = (old.fileOffset ?? 0) + range.upperBound - old.offset; result.append(after)
                }
            }
        }
        guard result.count < 65536 else { throw StorageFailure.localStorageFull }
        return result
    }
    public func prepareTruncate(nodeID: NodeID, fromGeneration: Int64, toGeneration: Int64,
                                logicalSize: Int64, base: ObjectLocator?, previousSnapshotID: UUID? = nil, size: Int64, mutationFingerprint: String? = nil) throws -> ContentSnapshot {
        guard size >= 0, logicalSize >= 0, fromGeneration >= 0, fromGeneration < Int64.max, toGeneration == fromGeneration + 1 else { throw StorageFailure.invalidRange }
        let previous = try previousSnapshotID.map { try self.snapshot(id: $0) } ?? latest(nodeID: nodeID, generation: fromGeneration)
        guard previous == nil || (previous!.nodeID == nodeID && previous!.generation == fromGeneration && previous!.size == logicalSize) else { throw StorageFailure.integrity }
        var snapshot = ContentSnapshot(id: UUID(), nodeID: nodeID, generation: toGeneration, size: size,
                                       base: previous?.base ?? base,
                                       baseReadableSize: min(previous?.baseReadableSize ?? min(base?.size ?? 0, logicalSize), size),
                                       extents: (previous?.extents ?? []).filter { $0.offset < size }.map { extent in
                                           var value = extent
                                           // A later extension must not resurrect bytes discarded by truncate.
                                           value.length = min(extent.length, size - extent.offset)
                                           return value
                                       })
        snapshot.extentRoot = previous?.extentRoot
        if size < logicalSize, let root = snapshot.extentRoot {
            snapshot.extentRoot = try index.replace(root: root, range: size..<ManagedExtentIndex.limit, extent: nil)
        }
        snapshot.externalSource = previous?.externalSource
        snapshot.mutationFingerprint = mutationFingerprint
        try persist(snapshot)
        return snapshot
    }
    public func registerSource(nodeID: NodeID, fromGeneration: Int64, toGeneration: Int64, source: ResidentSourceIdentity) throws -> ContentSnapshot {
        guard fromGeneration >= 0, fromGeneration < Int64.max, toGeneration == fromGeneration + 1, source.size >= 0 else { throw StorageFailure.invalidRange }
        _ = try source.read(range: 0..<0)
        var snapshot = ContentSnapshot(id: UUID(), nodeID: nodeID, generation: toGeneration, size: source.size, base: nil, baseReadableSize: source.size, extents: [])
        snapshot.externalSource = source
        try persist(snapshot)
        return snapshot
    }
    private func persist(_ snapshot: ContentSnapshot, afterLocalExtent extent: URL? = nil, orderedByNamespace: Bool = false) throws {
        try validate()
        let envelopeVersion = snapshot.extentRoot != nil && !snapshot.extents.isEmpty ? 2 : 1
        guard used <= maximumBytes else { throw StorageFailure.localStorageFull }
        guard snapshot.extents.count <= 65536 else { throw StorageFailure.localStorageFull }
        let path = directory.appendingPathComponent("snapshots/" + snapshot.id.uuidString + ".json")
        if let extent {
            do {
                // F_FULLFSYNC drains all earlier fsyncs on this device. The extent
                // and its directory are durable before atomicChecked renames this
                // temporary manifest into view. Namespace admission follows.
                try CoreFileIO.atomicChecked(snapshot, at: path, version: envelopeVersion, maximum: 16 * 1024 * 1024,
                    syncFile: orderedByNamespace ? CoreFileIO.requireOrderingBarrier : mediaBarrier)
            } catch let failure as POSIXError where failure.code == .ENOTSUP || failure.code == .EINVAL {
                // No manifest was installed: fully complete the ordinary, separate
                // extent barrier before retrying the ordinary snapshot protocol.
                groupLocalWriteBarriers = false
                let fd = open(extent.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw StorageFailure.integrity }
                defer { close(fd) }
                try CoreFileIO.sync(fd)
                try CoreFileIO.atomicChecked(snapshot, at: path, version: envelopeVersion, maximum: 16 * 1024 * 1024)
            }
        } else { try CoreFileIO.atomicChecked(snapshot, at: path, version: envelopeVersion, maximum: 16 * 1024 * 1024) }
        manifests[snapshot.id] = snapshot
    }
    /// Reuse a verified pack only when it covers the range in exactly the same order.
    /// Latest extents win. Return uncovered intervals for remote-base reads or zeros.
    public func overlay(snapshot: ContentSnapshot, range: Range<Int64>, into result: inout Data, remote: (any StorageRemote)? = nil, prefix: String? = nil) async throws -> [Range<Int64>] {
        try validate()
        guard range.lowerBound >= 0, range.upperBound <= snapshot.size,
              range.count <= 8 * 1024 * 1024, result.count == range.count else { throw StorageFailure.invalidRange }
        var covered = [Range<Int64>]()
        let indexedExtents = try snapshot.extentRoot.map { try index.read(root: $0, range: range) } ?? []
        let extents = indexedExtents + snapshot.extents
        let needed = Set(extents.map { $0.fileID })
        for id in needed { readingCloudExtents[id, default: 0] += 1 }
        defer {
            for id in needed {
                if readingCloudExtents[id] == 1 { readingCloudExtents.removeValue(forKey: id) }
                else { readingCloudExtents[id, default: 1] -= 1 }
            }
        }
        var previousObject: (id: UUID, bytes: Data)?
        for extent in extents.sorted(by: { $0.offset < $1.offset }) {
            let lower = max(extent.offset, range.lowerBound), upper = min(extent.offset + extent.length, range.upperBound)
            guard lower < upper else { continue }
            let bytes: Data
            let packed = packedMembers[extent.fileID]
            if let record = cloudExtents[packed?.objectID ?? extent.fileID] {
                guard let remote, prefix == record.prefix else { throw StorageFailure.busy }
                if previousObject?.id != record.id { previousObject = (record.id, try await verifiedBytes(record, remote: remote)) }
                guard let object = previousObject?.bytes else { throw StorageFailure.integrity }
                if let member = packed?.member {
                    guard member.checksum == extent.checksum, member.length == extent.storedLength else { throw StorageFailure.integrity }
                    bytes = object.subdata(in: Int(member.offset)..<Int(member.offset + member.length))
                } else {
                    guard record.checksum == extent.checksum, record.length == extent.storedLength else { throw StorageFailure.integrity }
                    bytes = object
                }
            } else {
                bytes = try CoreFileIO.read(directory.appendingPathComponent("extents/" + extent.fileID.uuidString), maximum: 8 * 1024 * 1024)
                guard bytes.count == extent.storedLength, CoreFileIO.hash(bytes) == extent.checksum else { throw StorageFailure.integrity }
            }
            result.replaceSubrange(Int(lower - range.lowerBound)..<Int(upper - range.lowerBound), with: bytes[Int((extent.fileOffset ?? 0) + lower - extent.offset)..<Int((extent.fileOffset ?? 0) + upper - extent.offset)])
            covered.append(lower..<upper)
        }
        var holes = [Range<Int64>](), cursor = range.lowerBound
        for segment in covered.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if cursor < segment.lowerBound { holes.append(cursor..<segment.lowerBound) }
            cursor = max(cursor, segment.upperBound)
        }
        if cursor < range.upperBound { holes.append(cursor..<range.upperBound) }
        return holes
    }
    func reclaimCloudExtents(prefix: String, remote: any StorageRemote) async throws {
        guard !cloudExtents.isEmpty else { return }
        try validate()
        let referenced = Set(manifests.values.flatMap { $0.extents.map(\.fileID) }).union(try index.reachable(Set(manifests.values.compactMap(\.extentRoot))).extents)
        let uploading = activeCloudExtents
        for record in cloudExtents.values where !uploading.contains(record.id) && !referenced.contains(record.id) {
            if let members = record.members, record.validator != nil,
               members.contains(where: { referenced.contains($0.id) || readingCloudExtents[$0.id] != nil }) { continue }
            guard record.prefix == prefix else { throw StorageFailure.integrity }
            guard cloudExtents[record.id] != nil, readingCloudExtents[record.id] == nil, activeCloudExtents.insert(record.id).inserted else { continue }
            defer { activeCloudExtents.remove(record.id) }
            if let object = try await remote.head(key: record.key) {
                guard object.operationID == record.id, object.size == record.length,
                      record.validator == nil || object.validator == record.validator else { throw StorageFailure.conflict }
                if record.validator == nil {
                    var verified = record
                    verified.validator = object.validator
                    _ = try await verifiedBytes(verified, remote: remote)
                }
                try await remote.removeWritebackObject(object, id: record.id, checksum: record.checksum)
            }
            try validate()
            try CoreFileIO.remove(cloudRecordPath(record.id))
            cloudExtents.removeValue(forKey: record.id)
            await verifiedCloudObjects.remove(key: record.key)
            for member in record.members ?? [] where packedMembers[member.id]?.objectID == record.id {
                packedMembers.removeValue(forKey: member.id)
            }
        }
    }

    /// Delete only snapshots proven cloud-published and no longer retained by a reader.
    /// The coordinator supplies *all* current/reader snapshot IDs. Shared extents remain.
    public func reclaim(published: Set<UUID>, retaining: Set<UUID>, discarded: Set<UUID> = []) throws {
        try validate()
        let discardable = discarded.subtracting(retaining)
        let intent = discardedSnapshots.union(discardable)
        if intent != discardedSnapshots {
            // This is a local deletion proof, never a cloud publication proof.
            // Persist before deleting any manifest or extent so restart can finish.
            try CoreFileIO.atomicChecked(intent, at: directory.appendingPathComponent("discarded-snapshots.json"))
            discardedSnapshots = intent
        }
        let removed = published.union(discardable).subtracting(retaining)
        var proven = publishedExtents
        for id in published { if let snapshot = manifests[id] { proven.formUnion(snapshot.extents.map(\.fileID)) } }
        let publishedRoots = Set(published.compactMap { manifests[$0]?.extentRoot })
        proven.formUnion(try index.reachable(publishedRoots).extents)
        if proven != publishedExtents {
            try CoreFileIO.atomicChecked(proven, at: directory.appendingPathComponent("published-extents.json"))
            publishedExtents = proven
        }
        for id in removed where manifests[id] != nil {
            try CoreFileIO.remove(directory.appendingPathComponent("snapshots/" + id.uuidString + ".json"))
            manifests.removeValue(forKey: id)
        }
        let referenced = Set(manifests.values.flatMap { $0.extents.map(\.fileID) }).union(try index.reachable(Set(manifests.values.compactMap(\.extentRoot))).extents)
        for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("extents"), includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: file.lastPathComponent), !referenced.contains(id), readingCloudExtents[id] == nil else { continue }
            let size = try CoreFileIO.allocatedSize(file)
            try CoreFileIO.remove(file); used -= size; allocated.removeValue(forKey: id)
        }
        if !publishedRoots.isEmpty, !manifests.values.contains(where: { $0.extentRoot != nil }) { try index.prune(keeping: []) }
        let retainedProofs = publishedExtents.intersection(allocated.keys)
        if retainedProofs != publishedExtents {
            try CoreFileIO.atomicChecked(retainedProofs, at: directory.appendingPathComponent("published-extents.json"))
            publishedExtents = retainedProofs
        }
    }
}

/// Only private, regular, same-user files are accepted. Atomic replace is followed by
/// directory fsync. Payload and manifest files request macOS full sync as well.
struct CoreDirectoryIdentity {
    let url: URL
    let device: dev_t
    let inode: ino_t
    init(_ url: URL) throws {
        self.url = url
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StorageFailure.integrity }
        device = info.st_dev; inode = info.st_ino
    }
    func validate() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_dev == device, info.st_ino == inode else { throw StorageFailure.integrity }
    }
}

enum CoreFileIO {
    private struct Checked: Codable { var version = 1; var payload: Data; var checksum: String }
    static func atomicChecked<T: Encodable>(_ value: T, at url: URL, version: Int = 1, maximum: Int = .max, syncFile: (Int32) throws -> Void = sync) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= maximum else { throw StorageFailure.localStorageFull }
        try atomic(encoder.encode(Checked(version: version, payload: payload, checksum: hash(payload))), at: url, syncFile: syncFile)
    }
    static func readChecked<T: Decodable>(_ type: T.Type, at url: URL, maximum: Int, allowedVersions: ClosedRange<Int> = 1...1) throws -> T {
        guard maximum <= Int.max / 2 else { throw StorageFailure.integrity }
        let checked = try JSONDecoder().decode(Checked.self, from: read(url, maximum: maximum * 2 + 1024))
        guard allowedVersions.contains(checked.version), checked.payload.count <= maximum, hash(checked.payload) == checked.checksum else { throw StorageFailure.integrity }
        return try JSONDecoder().decode(type, from: checked.payload)
    }
    private static let hex = Array("0123456789abcdef".utf8)
    static func hash(_ data: Data) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) { bytes.append(hex[Int(byte >> 4)]); bytes.append(hex[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func privateDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw StorageFailure.integrity }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &status) == 0 else { throw StorageFailure.integrity }
        }
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid(), status.st_mode & 0o077 == 0 else { throw StorageFailure.integrity }
    }
    static func regularSize(_ url: URL) throws -> Int64 {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, s.st_mode & 0o077 == 0 else { throw StorageFailure.integrity }
        return s.st_size
    }
    static func lock(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StorageFailure.integrity }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, s.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw StorageFailure.busy }
        return fd
    }
    static func validateLock(_ fd: Int32, at url: URL) throws {
        var opened = stat(), path = stat()
        guard fstat(fd, &opened) == 0, lstat(url.path, &path) == 0,
              path.st_mode & S_IFMT == S_IFREG, path.st_uid == getuid(), path.st_nlink == 1,
              path.st_mode & 0o077 == 0, opened.st_dev == path.st_dev, opened.st_ino == path.st_ino else { throw StorageFailure.integrity }
    }
    static func allocatedSize(_ url: URL) throws -> Int64 {
        _ = try regularSize(url); var s = stat()
        guard lstat(url.path, &s) == 0, s.st_blocks >= 0, s.st_blocks <= Int64.max / 512 else { throw StorageFailure.integrity }
        return Int64(s.st_blocks) * 512
    }
    static func reservation(_ bytes: Int64) throws -> Int64 {
        guard bytes >= 0, bytes <= Int64.max - 4095 else { throw StorageFailure.invalidRange }
        return ((bytes + 4095) / 4096) * 4096
    }
    static func sameAPFSVolume(_ a: URL, _ b: URL) -> Bool {
        var left = stat(), right = stat(), fs = statfs()
        guard lstat(a.path, &left) == 0, lstat(b.path, &right) == 0,
              left.st_dev == right.st_dev, statfs(a.path, &fs) == 0 else { return false }
        return withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "apfs"
    }
    static func syncToDevice(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw StorageFailure.integrity }
    }
    static func requireOrderingBarrier(_ fd: Int32) throws {
        guard fcntl(fd, F_BARRIERFSYNC) == 0 else {
            if errno == ENOTSUP || errno == EINVAL { throw POSIXError(.ENOTSUP) }
            throw StorageFailure.integrity
        }
    }
    static func requireMediaBarrier(_ fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC) == 0 else {
            if errno == ENOTSUP || errno == EINVAL { throw POSIXError(.ENOTSUP) }
            throw StorageFailure.integrity
        }
    }
    static func sync(_ fd: Int32) throws {
        // F_FULLFSYNC includes fsync and the device cache flush on macOS.
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard errno == ENOTSUP || errno == EINVAL, fsync(fd) == 0 else { throw StorageFailure.integrity }
    }
    static func atomic(_ data: Data, at url: URL, syncFile: (Int32) throws -> Void = sync) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StorageFailure.localStorageFull }
        var installed = false
        defer { close(fd); if !installed { unlink(temporary.path) } }
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StorageFailure.localStorageFull }
                done += count
            }
        }
        try syncFile(fd)
        guard rename(temporary.path, url.path) == 0 else { throw StorageFailure.integrity }
        installed = true
        try syncDirectory(url.deletingLastPathComponent())

    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let size = try regularSize(url)
        guard size >= 0, size <= maximum else { throw StorageFailure.integrity }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageFailure.integrity }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == size, info.st_nlink == 1, info.st_uid == getuid() else { throw StorageFailure.integrity }
        var data = Data(count: Int(size))
        try data.withUnsafeMutableBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.read(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StorageFailure.integrity }
                done += count
            }
        }
        return data
    }
    static func remove(_ url: URL) throws { _ = try regularSize(url); guard unlink(url.path) == 0 else { throw StorageFailure.integrity }; try syncDirectory(url.deletingLastPathComponent()) }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageFailure.integrity }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw StorageFailure.integrity }
    }
}
