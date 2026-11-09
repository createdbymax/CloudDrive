import Foundation
import Darwin

public struct RangeCacheAccounting: Codable, Equatable, Sendable {
    public var cleanBytes: Int64
    public var pinnedBytes: Int64
    public var maximumBytes: Int64
    public var entries: Int
}

/// Reproducible, checksum-validated clean chunks only. Dirty writes live in ContentStore.
/// Keys use stable node/generation identity, not a visible path, so a local rename
/// never invalidates a cached range. Provider validators fence uncached ranges.
public actor RangeCache {
    public let directory: URL
    public let chunkSize: Int
    private let maximumBytes: Int64
    private var owner: Int32 = -1
    private let identity: CoreDirectoryIdentity
    private var entries: [String: Entry] = [:]
    private var pins: Set<UUID> = []
    private var recursivePins: Set<UUID> = []
    private var requests: [UUID: PinProgress] = [:]
    private var pinJournal: PinJournal?
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var used: Int64 = 0
    private struct Entry: Codable {
        var nodeID: UUID
        var generation: Int64
        var length: Int
        var checksum: String
        var allocated: Int64? = nil
        var touched: Date
    }
    private struct Index: Codable { var version = 1; var entries: [String: Entry]; var pins: Set<UUID> }

    public init(directory: URL, maximumBytes: Int64 = 5 * 1024 * 1024 * 1024, chunkSize: Int = 1024 * 1024) throws {
        guard maximumBytes > 0, chunkSize >= 4096, chunkSize <= 8 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        self.directory = directory.standardizedFileURL; self.maximumBytes = maximumBytes; self.chunkSize = chunkSize
        try CoreFileIO.privateDirectory(self.directory)
        identity = try CoreDirectoryIdentity(self.directory)
        owner = try CoreFileIO.lock(self.directory.appendingPathComponent("owner.lock"))
        do {
        pinJournal = try PinJournal(directory: self.directory)
        let indexURL = self.directory.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let index = try CoreFileIO.readChecked(Index.self, at: indexURL, maximum: 8 * 1024 * 1024)
            guard index.version == 1, index.entries.count <= 16384 else { throw StorageFailure.integrity }
            self.pins = index.pins
            for (key, entry) in index.entries {
                guard key.count == 64, key.allSatisfy({ $0.isHexDigit }), entry.length > 0, entry.length <= chunkSize else { throw StorageFailure.integrity }
                let file = self.directory.appendingPathComponent(key)
                // Missing clean data is safe to refill. Corrupt pins remain unfulfilled;
                // they are not silently reported as available offline.
                if (try? CoreFileIO.regularSize(file)) == Int64(entry.length) { var measured = entry; measured.allocated = try CoreFileIO.allocatedSize(file); entries[key] = measured; used += measured.allocated! }
            }
        }
        if let pinJournal {
            // Import only the explicit old pin set from this new engine's first
            // checked-index prototype. New requests live in the essential journal.
            let saved = try pinJournal.all()
            if pinJournal.createdFresh && saved.isEmpty {
                for id in pins { try pinJournal.put(PinProgress(nodeID: id, recursive: false, generation: 0, size: 0, completedBytes: 0, state: "pending", error: nil)) }
            }
            for request in try pinJournal.all() { requests[request.nodeID] = request }
            pins = Set(requests.keys); recursivePins = Set(requests.values.filter(\.recursive).map(\.nodeID))
        }
        for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            let retained = entries[name] != nil
            if name.count == 64 && name.allSatisfy({ $0.isHexDigit }) && !retained { try CoreFileIO.remove(file) }
        }
        } catch { close(owner); owner = -1; throw error }
    }
    deinit { if owner >= 0 { close(owner) } }
    private func validate() throws { try identity.validate(); try CoreFileIO.validateLock(owner, at: directory.appendingPathComponent("owner.lock")); try pinJournal?.validate() }
    public func accounting() -> RangeCacheAccounting {
        .init(cleanBytes: used, pinnedBytes: entries.values.filter { pins.contains($0.nodeID) }.reduce(0) { $0 + ($1.allocated ?? Int64($1.length)) }, maximumBytes: maximumBytes, entries: entries.count)
    }
    public func pin(nodeID: NodeID, recursive: Bool = false) throws {
        try validate()
        var request = requests[nodeID] ?? PinProgress(nodeID: nodeID, recursive: recursive, generation: 0, size: 0, completedBytes: 0, state: "pending", error: nil)
        request.recursive = recursive || request.recursive
        try savePin(request)
    }
    public func requestPin(node: NamespaceNode, recursive: Bool = false) throws {
        try validate()
        let generation = node.kind == .directory ? node.metadataGeneration : node.contentGeneration
        if let previous = requests[node.id], previous.generation == generation, previous.size == node.size,
           previous.state == "complete", previous.recursive == recursive { return }
        try savePin(PinProgress(nodeID: node.id, recursive: recursive, generation: generation, size: node.kind == .file ? node.size : 0,
                                completedBytes: 0, state: "pending", error: nil))
    }
    public func updatePin(nodeID: NodeID, completedBytes: Int64, state: String, error: String? = nil) throws {
        try validate(); guard var request = requests[nodeID] else { throw StorageFailure.notFound }
        request.completedBytes = min(request.size, completedBytes); request.state = state; request.error = error
        try savePin(request)
    }
    private func savePin(_ request: PinProgress) throws {
        guard requests[request.nodeID] != nil || requests.count < 1_000_000, let pinJournal else { throw StorageFailure.localStorageFull }
        try pinJournal.put(request); requests[request.nodeID] = request; pins.insert(request.nodeID)
        if request.recursive { recursivePins.insert(request.nodeID) } else { recursivePins.remove(request.nodeID) }
    }
    public func unpin(nodeID: NodeID) throws {
        try validate(); try pinJournal?.remove(nodeID); requests.removeValue(forKey: nodeID); pins.remove(nodeID); recursivePins.remove(nodeID)
    }
    public func pinRequest(nodeID: NodeID) throws -> PinProgress? { try validate(); return requests[nodeID] }
    public func pinRequests() throws -> [PinProgress] { try validate(); return Array(requests.values) }
    func changeMayAffectPin(nodeID: NodeID) -> Bool { pins.contains(nodeID) || !recursivePins.isEmpty }
    public func isRecursivelyPinned(nodeID: NodeID) -> Bool { recursivePins.contains(nodeID) }
    public func isPinned(nodeID: NodeID) -> Bool { pins.contains(nodeID) }
    /// Bounded, current-generation disk verification. A completed pin alone is
    /// never evidence that its disposable cache survived removal or corruption.
    public func availability(nodes: [NamespaceNode], maximumVerificationBytes: Int = 16 * 1024 * 1024) throws -> [String: String] {
        try validate()
        var remaining = max(0, maximumVerificationBytes)
        var result: [String: String] = [:]
        for node in nodes {
            var state = "unknown"
            if let pin = requests[node.id] {
                if pin.state == "attention" { state = "attention" }
                else if pin.state != "complete" { state = "downloading" }
                else if node.kind == .file, node.stagedSnapshotID == nil,
                        pin.generation == node.contentGeneration, pin.size == node.size,
                        let locator = node.backing, locator.size == node.size,
                        let validator = locator.validator, !validator.isEmpty {
                    state = "availableOffline"
                    var offset: Int64 = 0
                    while offset < node.size {
                        let end = min(node.size, offset + Int64(chunkSize))
                        let length = Int(end - offset)
                        guard remaining >= length else { state = "unknown"; break }
                        remaining -= length
                        let identity = "\(node.id.uuidString):\(node.contentGeneration):\(validator):\(offset):\(end)"
                        let key = CoreFileIO.hash(Data(identity.utf8))
                        guard let entry = entries[key], entry.length == length,
                              let data = try? CoreFileIO.read(directory.appendingPathComponent(key), maximum: chunkSize),
                              data.count == length, CoreFileIO.hash(data) == entry.checksum else {
                            state = "attention"; break
                        }
                        offset = end
                    }
                }
            } else if node.kind == .file, node.stagedSnapshotID == nil,
                      !entries.values.contains(where: { $0.nodeID == node.id && $0.generation == node.contentGeneration }) {
                state = "remoteOnly"
            }
            result["availability:" + node.id.uuidString] = state
        }
        return result
    }
    public func free(nodeID: NodeID) throws {
        try validate()
        guard !pins.contains(nodeID) else { throw StorageFailure.busy }
        for key in entries.keys.filter({ entries[$0]?.nodeID == nodeID }) { try evict(key) }
        try persist()
    }
    public func read(nodeID: NodeID, generation: Int64, locator: ObjectLocator, range: Range<Int64>, remote: any StorageRemote, requireResident: Bool = false) async throws -> Data {
        try validate()
        guard let validator = locator.validator, !validator.isEmpty,
              range.lowerBound >= 0, range.upperBound <= locator.size,
              range.count <= 8 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        var result = Data(); result.reserveCapacity(range.count)
        var offset = range.lowerBound
        while offset < range.upperBound {
            let start = (offset / Int64(chunkSize)) * Int64(chunkSize)
            let end = min(locator.size, start + Int64(chunkSize))
            let bytes = try await chunk(nodeID: nodeID, generation: generation, locator: locator, validator: validator, range: start..<end, remote: remote, requireResident: requireResident)
            let takeEnd = min(end, range.upperBound)
            result.append(bytes[Int(offset - start)..<Int(takeEnd - start)])
            offset = takeEnd
        }
        return result
    }
    private func chunk(nodeID: NodeID, generation: Int64, locator: ObjectLocator, validator: String,
                       range: Range<Int64>, remote: any StorageRemote, requireResident: Bool) async throws -> Data {
        let identity = "\(nodeID.uuidString):\(generation):\(validator):\(range.lowerBound):\(range.upperBound)"
        let key = CoreFileIO.hash(Data(identity.utf8)), file = directory.appendingPathComponent(CoreFileIO.hash(Data(identity.utf8)))
        if var entry = entries[key] {
            if let data = try? CoreFileIO.read(file, maximum: chunkSize), data.count == entry.length, CoreFileIO.hash(data) == entry.checksum {
                entry.touched = Date(); entries[key] = entry
                return data
            }
            try evict(key); try persist()
        }
        if let task = inFlight[key] {
            let data = try await task.value
            if requireResident && entries[key] == nil { throw StorageFailure.localStorageFull }
            return data
        }
        let task = Task<Data, Error> { [self] in
            let response = try await remote.read(key: locator.key, range: range, validator: validator)
            guard response.offset == range.lowerBound, response.totalSize == locator.size,
                  response.validator == validator, response.data.count == range.count else { throw StorageFailure.invalidResponse }
            return try install(response.data, key: key, nodeID: nodeID, generation: generation)
        }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        let data = try await task.value
        if requireResident && entries[key] == nil { throw StorageFailure.localStorageFull }
        return data
    }
    private func install(_ data: Data, key: String, nodeID: NodeID, generation: Int64) throws -> Data {
        try validate()
        let file = directory.appendingPathComponent(key)
        // Every coalesced waiter observes installation before the shared task
        // completes. Ordinary online reads can bypass a full pinned cache;
        // a pin waiter separately requires a durable resident entry.
        guard try makeRoom(CoreFileIO.reservation(Int64(data.count))) else { return data }
        try CoreFileIO.atomic(data, at: file)
        let allocated = try CoreFileIO.allocatedSize(file)
        guard used <= maximumBytes - allocated else { try CoreFileIO.remove(file); return data }
        entries[key] = Entry(nodeID: nodeID, generation: generation, length: data.count, checksum: CoreFileIO.hash(data), allocated: allocated, touched: Date())
        used += allocated
        try persist()
        return data
    }
    private func makeRoom(_ bytes: Int64) throws -> Bool {
        guard bytes <= maximumBytes else { return false }
        let candidates = entries.filter { !pins.contains($0.value.nodeID) }.sorted { $0.value.touched < $1.value.touched }
        for (key, _) in candidates where used > maximumBytes - bytes || entries.count >= 16384 { try evict(key) }
        return used <= maximumBytes - bytes && entries.count < 16384
    }
    private func evict(_ key: String) throws {
        guard let entry = entries[key] else { return }
        let file = directory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: file.path) { try CoreFileIO.remove(file) }
        used -= entry.allocated ?? Int64(entry.length); entries.removeValue(forKey: key)
    }
    private func persist() throws { try validate(); try CoreFileIO.atomicChecked(Index(entries: entries, pins: []), at: directory.appendingPathComponent("index.json")) }
}
