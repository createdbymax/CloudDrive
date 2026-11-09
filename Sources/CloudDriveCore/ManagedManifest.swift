import Foundation

public struct ManagedNodeRecord: Codable, Equatable, Sendable {
    public var id: NodeID
    public var inode: Int64? = nil
    public var parentID: NodeID?
    public var name: String
    public var kind: NamespaceNodeKind
    public var size: Int64
    public var generation: Int64
    public var metadataGeneration: Int64? = nil
    public var xattrs: [String: Data]? = nil
    public var deletedRevision: Int64? = nil
    public var modifiedAt: Date
    public var backing: ObjectLocator?
    public init(node: NamespaceNode, backing: ObjectLocator? = nil) {
        id = node.id; inode = node.inode; parentID = node.parentID; name = node.name; kind = node.kind
        size = node.size; generation = node.contentGeneration; metadataGeneration = node.metadataGeneration; deletedRevision = node.deletedRevision; modifiedAt = node.modifiedAt
        self.xattrs = node.xattrs
        self.backing = backing ?? node.backing
    }
}
public struct ManagedHead: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var volumeID: VolumeID
    public var commitID: String
}
public struct ManagedCommit: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var volumeID: VolumeID
    public var revision: Int64
    public var parentCommit: String?
    public var operationIDs: [UUID]
    public var nodeRoot: String?
    public var directoryRoot: String?
}
public struct ManagedPublication: Codable, Equatable, Sendable {
    public var head: ManagedHead
    public var commit: ManagedCommit
    public var expectedHeadValidator: String?
}

public struct ManagedSeedCheckpoint: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var volumeID: VolumeID
    public var rootID: NodeID
    public var revision: Int64
    public var operationID: UUID
    public var nodeRoot: String?
    public var directoryRoot: String?
    public var lastNodeID: String?
    public var count: Int = 0
    public var needsXattrs: Bool? = nil
}

/// Immutable hash-trie metadata; a node update rewrites a bounded leaf and its
/// ancestry. HEAD is a small CAS pointer, never a monolithic whole-drive JSON tree.
public actor ManagedManifestPublisher {
    private let remote: any StorageRemote
    private let prefix: String
    private let volumeID: VolumeID
    private var headValidator: String?
    private var currentCommit: ManagedCommit?
    private var currentCommitID: String?
    private var loaded = false
    // Only verified immutable pages enter this per-publisher cache. HEAD always
    // stays behind the provider's compare-and-swap write, including on retries.
    private let pages = NSCache<NSString, NSData>()
    private let expectedHead: StorageObject?
    private struct TriePage: Codable {
        var version = 1
        var depth: Int
        var records: [String: Data]
        var children: [String: String]
    }
    public init(remote: any StorageRemote, prefix: String, volumeID: VolumeID, expectedHead: StorageObject? = nil) {
        self.remote = remote; self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.clouddrive/v1"
        self.volumeID = volumeID; self.expectedHead = expectedHead
        pages.totalCostLimit = 128 * 1024 * 1024; pages.countLimit = 8192
    }
    public func load() async throws -> ManagedCommit? {
        if loaded { return currentCommit }
        let candidate: StorageObject?
        if let expectedHead { candidate = expectedHead }
        else { candidate = try await remote.head(key: prefix + "/HEAD") }
        guard let object = candidate else { loaded = true; return nil }
        guard object.key == prefix + "/HEAD" else { throw StorageFailure.integrity }
        let head: ManagedHead = try await decodeObject(object, as: ManagedHead.self, maximum: 4096)
        guard (1...2).contains(head.version), head.volumeID == volumeID, validHash(head.commitID) else { throw StorageFailure.integrity }
        let commit = try await readCommit(head.commitID)
        guard commit.volumeID == volumeID, commit.version == head.version else { throw StorageFailure.conflict }
        headValidator = object.validator; currentCommitID = head.commitID; currentCommit = commit; loaded = true
        return commit
    }
    /// Caller durably records this immutable intent before publish(). A replay uses
    /// the same commit ID and original expected HEAD validator after a lost response.
    public func prepare(revision: Int64, operationIDs: [UUID], updates: [ManagedNodeRecord], removals: [NodeID] = []) async throws -> ManagedPublication {
        _ = try await load()
        let base = currentCommit, parentCommit = currentCommitID, expectedValidator = headValidator
        guard operationIDs.count <= 256, updates.count <= 256, removals.count <= 256,
              revision >= (base?.revision ?? 0) else { throw StorageFailure.invalidRange }
        let nodeKeys = Set(removals.map(\.uuidString) + updates.map { $0.id.uuidString })
        let oldNodes = try await lookupMany(root: base?.nodeRoot, keys: nodeKeys)
        var nodeChanges: [String: TrieChange] = [:]
        var directoryEdits: [TrieChange] = []
        for id in removals {
            if let oldData = pendingValue(key: id.uuidString, changes: nodeChanges, base: oldNodes) {
                let old = try JSONDecoder().decode(ManagedNodeRecord.self, from: oldData)
                if let parent = old.parentID {
                    let key = directoryKey(parent: parent, name: old.name)
                    directoryEdits.append(TrieChange(key: key, value: nil))
                }
                nodeChanges[id.uuidString] = TrieChange(key: id.uuidString, value: nil)
            }
        }
        for node in updates {
            guard node.size >= 0, node.generation >= 0 else { throw StorageFailure.integrity }
            if let oldData = pendingValue(key: node.id.uuidString, changes: nodeChanges, base: oldNodes) {
                let old = try JSONDecoder().decode(ManagedNodeRecord.self, from: oldData)
                if let parent = old.parentID, parent != node.parentID || old.name != node.name || node.deletedRevision != nil {
                    let key = directoryKey(parent: parent, name: old.name)
                    directoryEdits.append(TrieChange(key: key, value: nil))
                }
            }
            nodeChanges[node.id.uuidString] = TrieChange(key: node.id.uuidString, value: try encode(node))
            if let parent = node.parentID, node.deletedRevision == nil {
                let key = directoryKey(parent: parent, name: node.name)
                directoryEdits.append(TrieChange(key: key, value: Data(node.id.uuidString.utf8)))
            }
        }
        // A removal before the first insertion already determines that key's
        // prior value. Fetch only the keys that need a base collision check.
        var seen = Set<String>(), directoryKeys = Set<String>()
        for edit in directoryEdits where seen.insert(edit.key).inserted && edit.value != nil {
            directoryKeys.insert(edit.key)
        }
        let oldDirectory = try await lookupMany(root: base?.directoryRoot, keys: directoryKeys)
        var directoryChanges: [String: TrieChange] = [:]
        for edit in directoryEdits {
            if let value = edit.value, let previous = pendingValue(key: edit.key, changes: directoryChanges, base: oldDirectory), previous != value {
                throw StorageFailure.conflict
            }
            directoryChanges[edit.key] = edit
        }
        // The node and directory tries are independent immutable page sets; write both
        // chains at once so one commit costs one round-trip chain instead of two.
        let nodeEdits = Array(nodeChanges.values), directoryEditList = Array(directoryChanges.values)
        async let nodeRootUpdate = updateMany(root: base?.nodeRoot, changes: nodeEdits, depth: 0, branch: "")
        async let directoryRootUpdate = updateMany(root: base?.directoryRoot, changes: directoryEditList, depth: 0, branch: "")
        let (nodeRoot, directoryRoot) = try await (nodeRootUpdate, directoryRootUpdate)
        let commit = ManagedCommit(version: max(base?.version ?? 1, updates.contains { $0.xattrs != nil } ? 2 : 1), volumeID: volumeID, revision: revision, parentCommit: parentCommit,
                                   operationIDs: operationIDs, nodeRoot: nodeRoot, directoryRoot: directoryRoot)
        let data = try encode(commit), id = CoreFileIO.hash(data)
        try await putImmutable(id, collection: "commits", data: data, operationID: operationIDs.first ?? UUID())
        return ManagedPublication(head: ManagedHead(version: commit.version, volumeID: volumeID, commitID: id), commit: commit, expectedHeadValidator: expectedValidator)
    }
    public func publish(_ publication: ManagedPublication, operationID: UUID) async throws {
        guard publication.head.volumeID == volumeID, publication.commit.volumeID == volumeID, publication.head.version == publication.commit.version,
              CoreFileIO.hash(try encode(publication.commit)) == publication.head.commitID else { throw StorageFailure.integrity }
        let condition = publication.expectedHeadValidator.map(StorageCondition.matches) ?? .absent
        do {
            let object = try await remote.put(key: prefix + "/HEAD", data: encode(publication.head), condition: condition, operationID: operationID)
            headValidator = object.validator; currentCommitID = publication.head.commitID; currentCommit = publication.commit; loaded = true
        } catch {
            // A successful PUT may have lost its response. Confirm this exact commit
            // or a descendant containing it before classifying the operation.
            if try await reconcile(publication, operationID: operationID) { return }
            throw error
        }
    }
    public func beginSeed(revision: Int64, rootID: NodeID, operationID: UUID) async throws -> ManagedSeedCheckpoint {
        guard try await load() == nil else { throw StorageFailure.conflict }
        return ManagedSeedCheckpoint(volumeID: volumeID, rootID: rootID, revision: revision,
                                     operationID: operationID, nodeRoot: nil, directoryRoot: nil, lastNodeID: nil)
    }
    public func appendSeed(_ checkpoint: ManagedSeedCheckpoint, records: [ManagedNodeRecord]) async throws -> ManagedSeedCheckpoint {
        guard checkpoint.version == 1, checkpoint.volumeID == volumeID, records.count <= 4096,
              checkpoint.count <= 1_000_000 - records.count else { throw StorageFailure.integrity }
        var result = checkpoint
        var nodes = [String: Data](), names = [String: Data]()
        for record in records {
            if let values = record.xattrs { try ManagedXattrs.validate(values); result.needsXattrs = true }
            let key = record.id.uuidString
            guard result.lastNodeID == nil || key > result.lastNodeID!, record.size >= 0,
                  record.parentID != nil || record.id == checkpoint.rootID else { throw StorageFailure.integrity }
            let value = try encode(record)
            guard value.count <= 16 * 1024 else { throw StorageFailure.integrity }
            nodes[key] = value
            if let parent = record.parentID {
                let name = directoryKey(parent: parent, name: record.name)
                guard name.utf8.count <= 1024, names.updateValue(Data(key.utf8), forKey: name) == nil else { throw StorageFailure.conflict }
            }
            result.lastNodeID = key; result.count += 1
        }
        result.nodeRoot = try await seedPages(root: result.nodeRoot, additions: nodes, branch: "", operationID: result.operationID)
        result.directoryRoot = try await seedPages(root: result.directoryRoot, additions: names, branch: "", operationID: result.operationID)
        return result
    }
    // Build the same content-addressed trie as ordinary updates. Only persist each
    // touched page once per import batch. Parallelism is confined to the root.
    private func seedPages(root: String?, additions: [String: Data], branch: String, operationID: UUID) async throws -> String? {
        guard !additions.isEmpty else { return root }
        let depth = branch.count
        guard depth <= 64 else { throw StorageFailure.integrity }
        var page = TriePage(depth: depth, records: [:], children: [:])
        if let root { page = try await readPage(root, depth: depth, prefix: branch) }
        var incoming = additions
        if page.children.isEmpty {
            try incoming.merge(page.records) { new, old in
                guard new == old else { throw StorageFailure.conflict }; return old
            }
            page.records = Self.fitsLeaf(incoming) ? incoming : [:]
        }
        if page.records.isEmpty {
            guard depth < 64 else { throw StorageFailure.integrity }
            var buckets = [String: [String: Data]]()
            for (key, value) in incoming {
                let nibble = String(Array(CoreFileIO.hash(Data(key.utf8)))[depth])
                buckets[nibble, default: [:]][key] = value
            }
            if depth == 0 {
                let children = page.children
                try await withThrowingTaskGroup(of: (String, String?).self) { group in
                    var active = 0
                    for (nibble, records) in buckets {
                        if active == 8, let (name, id) = try await group.next() {
                            page.children[name] = id; active -= 1
                        }
                        group.addTask {
                            (nibble, try await self.seedPages(root: children[nibble], additions: records, branch: nibble, operationID: operationID))
                        }
                        active += 1
                    }
                    for try await (name, id) in group { page.children[name] = id }
                }
            } else {
                for (nibble, records) in buckets {
                    page.children[nibble] = try await seedPages(root: page.children[nibble], additions: records, branch: branch + nibble, operationID: operationID)
                }
            }
        }
        let data = try encode(page)
        guard data.count <= 256 * 1024 else { throw StorageFailure.integrity }
        let id = CoreFileIO.hash(data)
        if id != root {
            try await putImmutable(id, collection: "metadata", data: data, operationID: operationID)
            pages.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        }
        return id
    }
    public func finishSeed(_ checkpoint: ManagedSeedCheckpoint) async throws -> ManagedPublication {
        guard checkpoint.volumeID == volumeID, checkpoint.version == 1, checkpoint.count > 0,
              let rootData = try await lookup(root: checkpoint.nodeRoot, key: checkpoint.rootID.uuidString),
              try JSONDecoder().decode(ManagedNodeRecord.self, from: rootData).parentID == nil else { throw StorageFailure.integrity }
        let commit = ManagedCommit(version: checkpoint.needsXattrs == true ? 2 : 1, volumeID: volumeID, revision: checkpoint.revision, parentCommit: nil,
                                   operationIDs: [checkpoint.operationID], nodeRoot: checkpoint.nodeRoot, directoryRoot: checkpoint.directoryRoot)
        let data = try encode(commit), id = CoreFileIO.hash(data)
        try await putImmutable(id, collection: "commits", data: data, operationID: checkpoint.operationID)
        return ManagedPublication(head: ManagedHead(version: commit.version, volumeID: volumeID, commitID: id), commit: commit, expectedHeadValidator: nil)
    }
    /// A complete, hash-verified snapshot for explicit loss recovery/export. Missing
    /// pages fail closed. No empty replacement namespace is synthesized.
    public func exportRecords(maximumRecords: Int = 1_000_000, maximumDecodedBytes: Int = 128 * 1024 * 1024) async throws -> [ManagedNodeRecord] {
        guard (1...1_000_000).contains(maximumRecords), (1...(128 * 1024 * 1024)).contains(maximumDecodedBytes) else { throw StorageFailure.invalidRange }
        var decodedBytes = 0
        guard let commit = try await load(), let root = commit.nodeRoot else { throw StorageFailure.notFound }
        var result = [ManagedNodeRecord](), pending = [(root, 0, "")], visited = Set<String>(), nodeIDs = Set<UUID>()
        while let (id, depth, prefix) = pending.popLast() {
            guard visited.insert(id).inserted, visited.count <= 1_000_000 else { throw StorageFailure.integrity }
            let page = try await readPage(id, depth: depth, prefix: prefix)
            for (key, value) in page.records {
                guard value.count <= maximumDecodedBytes - decodedBytes, result.count < maximumRecords else { throw StorageFailure.localStorageFull }
                decodedBytes += value.count
                let node = try JSONDecoder().decode(ManagedNodeRecord.self, from: value)
                guard node.id.uuidString == key, nodeIDs.insert(node.id).inserted, node.size >= 0, node.generation >= 0 else { throw StorageFailure.integrity }
                result.append(node)
                guard result.count <= 1_000_000 else { throw StorageFailure.integrity }
            }
            pending.append(contentsOf: page.children.map { ($0.value, depth + 1, prefix + $0.key) })
        }
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        var visibility = [UUID: Bool]()
        func visible(_ id: UUID) throws -> Bool {
            var cursor: UUID? = id, chain = [UUID](), seen = Set<UUID>(), allowed = true
            while let value = cursor {
                if let cached = visibility[value] { allowed = cached; break }
                guard seen.insert(value).inserted, seen.count <= 4096, let node = byID[value] else { throw StorageFailure.integrity }
                chain.append(value)
                if node.deletedRevision != nil { allowed = false; break }
                cursor = node.parentID
            }
            for value in chain { visibility[value] = allowed }
            return allowed
        }
        return try result.filter { try visible($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func rawNode(id: NodeID) async throws -> ManagedNodeRecord? {
        guard let data = try await lookup(root: currentCommit?.nodeRoot, key: id.uuidString) else { return nil }
        let node = try JSONDecoder().decode(ManagedNodeRecord.self, from: data)
        guard node.id == id, node.size >= 0, node.generation >= 0 else { throw StorageFailure.integrity }
        return node
    }
    public func node(id: NodeID) async throws -> ManagedNodeRecord? {
        _ = try await load()
        guard let node = try await rawNode(id: id) else { return nil }
        var cursor: ManagedNodeRecord? = node, seen = Set<UUID>()
        while let value = cursor {
            guard seen.insert(value.id).inserted, seen.count <= 4096 else { throw StorageFailure.integrity }
            if value.deletedRevision != nil { return nil }
            if let parent = value.parentID { guard let found = try await rawNode(id: parent) else { throw StorageFailure.integrity }; cursor = found }
            else { cursor = nil }
        }
        return node
    }
    public func lookup(parentID: NodeID, name: String) async throws -> ManagedNodeRecord? {
        _ = try await load()
        guard try await node(id: parentID) != nil else { return nil }
        guard let value = try await lookup(root: currentCommit?.directoryRoot, key: directoryKey(parent: parentID, name: name)),
              let string = String(data: value, encoding: .utf8), let id = UUID(uuidString: string) else { return nil }
        guard let found = try await node(id: id) else { return nil }
        guard found.parentID == parentID, directoryKey(parent: parentID, name: found.name) == directoryKey(parent: parentID, name: name) else { throw StorageFailure.integrity }
        return found
    }
    private func reconcile(_ publication: ManagedPublication, operationID: UUID) async throws -> Bool {
        guard let object = try await remote.head(key: prefix + "/HEAD") else { return false }
        let head: ManagedHead = try await decodeObject(object, as: ManagedHead.self, maximum: 4096)
        guard head.volumeID == volumeID, (1...2).contains(head.version) else { throw StorageFailure.conflict }
        var cursor: String? = head.commitID, visited = Set<String>()
        for _ in 0..<1024 {
            guard let id = cursor, visited.insert(id).inserted else { return false }
            let commit = try await readCommit(id)
            guard commit.volumeID == volumeID else { throw StorageFailure.integrity }
            if id == publication.head.commitID || commit.operationIDs.contains(operationID) {
                // Include pointer's current commit, not the older reconciled ancestor.
                currentCommitID = head.commitID; currentCommit = try await readCommit(head.commitID)
                headValidator = object.validator; loaded = true; return true
            }
            cursor = commit.parentCommit
        }
        return false
    }
    private func readCommit(_ id: String) async throws -> ManagedCommit {
        guard validHash(id) else { throw StorageFailure.integrity }
        let data = try await readImmutable(id, collection: "commits")
        let commit = try JSONDecoder().decode(ManagedCommit.self, from: data)
        guard (1...2).contains(commit.version), commit.operationIDs.count <= 256,
              commit.nodeRoot.map(validHash) ?? true, commit.directoryRoot.map(validHash) ?? true else { throw StorageFailure.integrity }
        return commit
    }
    private func lookup(root: String?, key: String) async throws -> Data? {
        var cursor = root, depth = 0
        let digest = Array(CoreFileIO.hash(Data(key.utf8)))
        while let id = cursor {
            guard depth <= 64 else { throw StorageFailure.integrity }
            let page = try await readPage(id, depth: depth, prefix: String(digest.prefix(depth)))
            if page.children.isEmpty { return page.records[key] }
            guard depth < digest.count else { throw StorageFailure.integrity }
            cursor = page.children[String(digest[depth])]; depth += 1
        }
        return nil
    }
    private struct TrieLookup: Sendable {
        let key: String
        let digest: [Character]
    }
    private func lookupMany(root: String?, keys: Set<String>) async throws -> [String: Data] {
        let lookups = keys.map { TrieLookup(key: $0, digest: Array(CoreFileIO.hash(Data($0.utf8)))) }
        return try await lookupMany(root: root, lookups: lookups, branch: "", parallel: true)
    }
    /// Walk the shared ancestry once for all keys. Fan out only at the first
    /// branching level, so deep subtrees cannot multiply the request budget.
    private func lookupMany(root: String?, lookups: [TrieLookup], branch: String, parallel: Bool) async throws -> [String: Data] {
        guard let root, !lookups.isEmpty else { return [:] }
        let depth = branch.count
        guard depth <= 64 else { throw StorageFailure.integrity }
        let page = try await readPage(root, depth: depth, prefix: branch)
        if page.children.isEmpty {
            var values: [String: Data] = [:]
            for lookup in lookups { values[lookup.key] = page.records[lookup.key] }
            return values
        }
        guard depth < 64 else { throw StorageFailure.integrity }
        let groups = Dictionary(grouping: lookups) { String($0.digest[depth]) }
        var values: [String: Data] = [:]
        if parallel, groups.count > 1 {
            try await withThrowingTaskGroup(of: [String: Data].self) { group in
                var active = 0
                for (nibble, keys) in groups {
                    guard let child = page.children[nibble] else { continue }
                    if active == 8, let result = try await group.next() {
                        values.merge(result) { _, new in new }
                        active -= 1
                    }
                    group.addTask {
                        try await self.lookupMany(root: child, lookups: keys, branch: branch + nibble, parallel: false)
                    }
                    active += 1
                }
                for try await result in group { values.merge(result) { _, new in new } }
            }
        } else {
            for (nibble, keys) in groups {
                let result = try await lookupMany(root: page.children[nibble], lookups: keys, branch: branch + nibble, parallel: parallel)
                values.merge(result) { _, new in new }
            }
        }
        return values
    }
    private static func fitsLeaf(_ records: [String: Data]) -> Bool {
        // Values are base64-encoded in the enclosing 256 KiB page.
        records.count <= 64 && records.reduce(0) { $0 + $1.key.utf8.count + $1.value.count } <= 144 * 1024
    }
    private struct TrieChange: Sendable { let key: String; let value: Data? }
    private func pendingValue(key: String, changes: [String: TrieChange], base: [String: Data]) -> Data? {
        if let change = changes[key] { return change.value }
        return base[key]
    }
    /// Apply a publication's edits together, rewriting each shared ancestor once.
    private func updateMany(root: String?, changes: [TrieChange], depth: Int, branch: String) async throws -> String? {
        guard !changes.isEmpty else { return root }
        guard depth <= 64, changes.allSatisfy({ $0.key.utf8.count <= 1024 && ($0.value?.count ?? 0) <= 16 * 1024 }) else { throw StorageFailure.integrity }
        var page: TriePage
        if let root { page = try await readPage(root, depth: depth, prefix: branch) }
        else { page = TriePage(depth: depth, records: [:], children: [:]) }
        if page.children.isEmpty {
            let previous = page.records
            for change in changes { page.records[change.key] = change.value }
            if page.records == previous { return root }
            if page.records.isEmpty { return nil }
            if !Self.fitsLeaf(page.records) {
                guard depth < 64 else { throw StorageFailure.integrity }
                return try await seedPages(root: nil, additions: page.records, branch: branch, operationID: UUID())
            }
        } else {
            guard depth < 64 else { throw StorageFailure.integrity }
            let groups = Dictionary(grouping: changes) { String(Array(CoreFileIO.hash(Data($0.key.utf8)))[depth]) }
            let previous = page.children
            if depth == 0, groups.count > 1 {
                // Each root branch writes immutable pages. The root page and
                // final conditional HEAD still wait for all changed branches.
                try await withThrowingTaskGroup(of: (String, String?).self) { group in
                    var active = 0
                    for (nibble, edits) in groups {
                        if active == 8, let (name, id) = try await group.next() {
                            page.children[name] = id
                            active -= 1
                        }
                        group.addTask {
                            (nibble, try await self.updateMany(root: previous[nibble], changes: edits, depth: 1, branch: nibble))
                        }
                        active += 1
                    }
                    for try await (name, id) in group { page.children[name] = id }
                }
            } else {
                for (nibble, edits) in groups {
                    page.children[nibble] = try await updateMany(root: previous[nibble], changes: edits, depth: depth + 1, branch: branch + nibble)
                }
            }
            if page.children == previous { return root }
            if page.children.isEmpty { return nil }
        }
        let data = try encode(page)
        guard data.count <= 256 * 1024 else { throw StorageFailure.integrity }
        let id = CoreFileIO.hash(data)
        try await putImmutable(id, collection: "metadata", data: data, operationID: UUID())
        pages.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        return id
    }
    private func readPage(_ id: String, depth: Int, prefix: String) async throws -> TriePage {
        guard validHash(id) else { throw StorageFailure.integrity }
        let data: Data
        if let cached = pages.object(forKey: id as NSString) { data = cached as Data }
        else {
            data = try await readImmutable(id, collection: "metadata")
            pages.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        }
        let page = try JSONDecoder().decode(TriePage.self, from: data)
        guard prefix.count == depth, page.version == 1, page.depth == depth, page.records.count <= 64, page.children.count <= 16,
              page.records.isEmpty || page.children.isEmpty,
              page.records.keys.allSatisfy({ CoreFileIO.hash(Data($0.utf8)).hasPrefix(prefix) }),
              page.children.allSatisfy({ $0.key.count == 1 && $0.key.allSatisfy(\.isHexDigit) && validHash($0.value) }) else { throw StorageFailure.integrity }
        return page
    }
    private func readImmutable(_ id: String, collection: String) async throws -> Data {
        do {
            return try await remote.readContentAddressed(key: prefix + "/" + collection + "/" + id,
                                                         maximum: 256 * 1024, checksum: id)
        } catch StorageFailure.notFound { throw StorageFailure.integrity }
    }
    private func putImmutable(_ id: String, collection: String, data: Data, operationID: UUID) async throws {
        let key = prefix + "/" + collection + "/" + id
        do { try await remote.putContentAddressed(key: key, data: data, operationID: operationID) }
        catch let putError {
            do {
                let existing = try await readImmutable(id, collection: collection)
                guard existing == data else { throw putError }
            } catch StorageFailure.integrity {
                // A missing or mismatched object preserves the original PUT
                // error. Keep the prior bounds and framing checks on this path.
                guard let object = try await remote.head(key: key), try await bytes(object, maximum: 256 * 1024) == data else { throw putError }
            }
        }
    }
    private func decodeObject<T: Decodable>(_ object: StorageObject, as: T.Type, maximum: Int) async throws -> T { try JSONDecoder().decode(T.self, from: await bytes(object, maximum: maximum)) }
    private func bytes(_ object: StorageObject, maximum: Int) async throws -> Data {
        guard object.size >= 0, object.size <= maximum else { throw StorageFailure.integrity }
        if object.size == 0 { return Data() }
        let response = try await remote.read(key: object.key, range: 0..<object.size, validator: object.validator)
        guard response.offset == 0, response.totalSize == object.size, response.data.count == object.size, response.validator == object.validator else { throw StorageFailure.invalidResponse }
        return response.data
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func validHash(_ id: String) -> Bool { id.count == 64 && id.allSatisfy(\.isHexDigit) }
    private func directoryKey(parent: NodeID, name: String) -> String { parent.uuidString + "/" + NamespaceStore.comparison(name) }
}
