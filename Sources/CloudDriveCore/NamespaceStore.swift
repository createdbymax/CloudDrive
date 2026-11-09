import Foundation
import SQLite3
import CryptoKit
import Darwin
import os

/// The sole owner of the authoritative tree. Namespace edits, their remote intent and
/// search notifications share one FULL-synchronous SQLite transaction. No network work
/// or descendant traversal occurs in the rename acknowledgement path.
public actor NamespaceStore {
    let database: NamespaceDatabase
    public let directory: URL
    public let binding: String
    let admissionFenceDirectory: URL?

    public init(directory: URL, binding: String, mode: NamespaceStorageMode = .compatible, volumeID: UUID? = nil, rootID: UUID? = nil) throws {
        guard !binding.isEmpty, binding.utf8.count <= 1024 else { throw NamespaceFailure.bindingMismatch }
        self.directory = directory; self.binding = binding
        database = try NamespaceDatabase(directory: directory, binding: binding, mode: mode, volumeID: volumeID, rootID: rootID)
        admissionFenceDirectory = database.supportsAdmissionFence ? directory : nil
    }

    public func close() { database.close() }
    public func sealOpenWrites() throws { try database.validate(); try database.sealOpenWrites() }
    func sealIdleOpenWrites() throws {
        if database.needsIdleSeal { try sealOpenWrites() }
    }

    public func volume() throws -> NamespaceVolume { try database.validate(); return try volumeUnchecked() }
    func volumeUnchecked() throws -> NamespaceVolume {
        let q = try database.query("SELECT id,root,binding,mode,revision,published FROM volume"); defer { sqlite3_finalize(q) }
        guard sqlite3_step(q) == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)),
              let root = UUID(uuidString: database.text(q, 1)), let mode = NamespaceStorageMode(rawValue: database.text(q, 3)) else { throw NamespaceFailure.corrupt }
        return NamespaceVolume(id: id, rootID: root, binding: database.text(q, 2), mode: mode,
                               revision: sqlite3_column_int64(q, 4), publishedRevision: sqlite3_column_int64(q, 5), canCreateNativeXattrs: mode == .managed)
    }

    public func node(_ id: NodeID) throws -> NamespaceNode {
        try database.validate(); try ensureNotRestoring(); let value = try rawNode(id); try assertVisible(value); return value
    }
    /// Open handles may retain content after unlink. Callers must already own that handle.
    public func retainedNode(_ id: NodeID) throws -> NamespaceNode { try database.validate(); try ensureNotRestoring(); return try rawNode(id) }
    public func node(inode: Int64) throws -> NamespaceNode {
        try database.validate(); try ensureNotRestoring()
        let q = try database.query("SELECT id FROM nodes WHERE inode=?"); defer { sqlite3_finalize(q) }
        database.bind(inode, q, 1)
        guard sqlite3_step(q) == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)) else { throw NamespaceFailure.notFound }
        let value = try rawNode(id); try assertVisible(value); return value
    }
    public func lookup(parentID: NodeID, name: String) throws -> NamespaceNode? {
        try database.validate(); try ensureNotRestoring(); try Self.validateName(name); try assertDirectory(parentID)
        return try lookupUnchecked(parentID: parentID, name: name)
    }
    func lookupUnchecked(parentID: NodeID, name: String) throws -> NamespaceNode? {
        let q = try database.query("SELECT id FROM nodes WHERE parent=? AND comparison=? AND deleted IS NULL"); defer { sqlite3_finalize(q) }
        database.bind(parentID.uuidString, q, 1); database.bind(Self.comparison(name), q, 2)
        let result = sqlite3_step(q)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)) else { throw NamespaceFailure.storage }
        return try rawNode(id)
    }
    public func list(parentID: NodeID, after: String? = nil, limit: Int = 256, includeDotInodes: Bool = false) throws -> NamespacePage {
        try database.validate(); try ensureNotRestoring(); try assertDirectory(parentID)
        guard (1...10_000).contains(limit), after == nil || UUID(uuidString: after!) != nil else { throw NamespaceFailure.limitExceeded }
        // Fetch the full page in one statement rather than preparing a node query per child.
        let q = try database.query("SELECT \(Self.nodeColumns),id FROM nodes WHERE parent=? AND deleted IS NULL AND id>? ORDER BY id LIMIT ?")
        defer { sqlite3_finalize(q) }; database.bind(parentID.uuidString, q, 1); database.bind(after.flatMap { UUID(uuidString: $0)?.uuidString } ?? "", q, 2); database.bind(Int64(limit + 1), q, 3)
        var nodes: [NamespaceNode] = []
        while true {
            let r = sqlite3_step(q); if r == SQLITE_DONE { break }
            guard r == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 12)) else { throw NamespaceFailure.storage }
            nodes.append(try decodeNode(q, id: id))
        }
        let hasMore = nodes.count > limit; if hasMore { nodes.removeLast() }
        var page = NamespacePage(nodes: nodes, next: hasMore ? nodes.last?.id.uuidString : nil, revision: try volumeUnchecked().revision)
        if includeDotInodes {
            let dots = try database.query("SELECT d.inode,COALESCE(p.inode,d.inode) FROM nodes d LEFT JOIN nodes p ON p.id=d.parent WHERE d.id=?")
            defer { sqlite3_finalize(dots) }
            database.bind(parentID.uuidString, dots, 1)
            guard sqlite3_step(dots) == SQLITE_ROW else { throw NamespaceFailure.corrupt }
            page.dotInodes = (sqlite3_column_int64(dots, 0), sqlite3_column_int64(dots, 1))
        }
        return page
    }

    /// A bounded metadata page for initial publication/export. Descendants of a
    /// retained tombstone are excluded without changing their stored identities.
    public func allNodes(after: String? = nil, limit: Int = 256) throws -> NamespacePage {
        try database.validate(); try ensureNotRestoring()
        guard (1...10_000).contains(limit), after == nil || UUID(uuidString: after!) != nil else { throw NamespaceFailure.limitExceeded }
        var cursor = after.flatMap { UUID(uuidString: $0)?.uuidString } ?? "", values: [NamespaceNode] = [], inspected = 0
        var exhausted = false
        while values.count < limit {
            try Task.checkCancellation()
            let q = try database.query("SELECT id FROM nodes WHERE deleted IS NULL AND id>? ORDER BY id LIMIT 512")
            database.bind(cursor, q, 1); var ids: [UUID] = []
            while true {
                let status = sqlite3_step(q); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)) else { sqlite3_finalize(q); throw NamespaceFailure.corrupt }; ids.append(id)
            }
            sqlite3_finalize(q)
            if ids.isEmpty { exhausted = true; break }
            for id in ids {
                inspected += 1; guard inspected <= 50_000 else { throw NamespaceFailure.limitExceeded }
                let value = try rawNode(id)
                do { try assertVisible(value); values.append(value) } catch NamespaceFailure.notFound { }
                cursor = id.uuidString
                if values.count == limit { break }
            }
            if ids.count < 512 && values.count < limit { exhausted = true; break }
        }
        return NamespacePage(nodes: values, next: exhausted ? nil : cursor, revision: try volumeUnchecked().revision)
    }

    public func create(parentID: NodeID, name: String, kind: NamespaceNodeKind, backing: ObjectLocator? = nil, operationID: UUID? = nil, nativeXattrs: Bool = false) throws -> NamespaceNode {
        let signature = try requestDigest(.init(kind: .create, parent: parentID, name: name, nodeKind: kind, backing: backing, xattrPolicy: nativeXattrs ? "native" : nil))
        return try database.transaction {
            try ensureNotRestoring()
            if let previous = try replay(operationID, digest: signature) { return try rawNode(previous.nodeID) }
            try Self.validateName(name); try assertDirectory(parentID)
            guard try lookupUnchecked(parentID: parentID, name: name) == nil else { throw NamespaceFailure.collision }
            if let backing { try Self.validateLocator(backing) }
            let revision = try advanceRevision(), id = UUID()
            try insertNode(id: id, parent: parentID, name: name, kind: kind, size: backing?.size ?? 0, modified: Date(), backing: backing)
            if nativeXattrs, backing == nil { try enableNewXattrs(id: id, parent: parentID, name: name) }
            try touchParents([parentID], revision: revision)
            let result = try rawNode(id)
            _ = try insertOperation(kind: .create, node: result, revision: revision, source: nil, destination: try pathUnchecked(id), operationID: operationID, requestDigest: signature)
            return result
        }
    }

    /// Admit a resident source/staged snapshot as one file generation. The caller
    /// durably prepares the source reference first; no empty placeholder is exposed.
    public func createContent(parentID: NodeID, name: String, nodeID: UUID, snapshotID: UUID, size: Int64, operationID: UUID? = nil, checksum: String? = nil, nativeXattrs: Bool = false) throws -> NamespaceNode {
        let signature = try requestDigest(.init(kind: .write, node: nodeID, parent: parentID, name: name, expectedGeneration: 0, newSize: size, snapshot: snapshotID, checksum: checksum, xattrPolicy: nativeXattrs ? "native" : nil))
        return try database.transaction {
            try ensureNotRestoring()
            if let previous = try replay(operationID, digest: signature) { return try rawNode(previous.nodeID) }
            try Self.validateName(name); try assertDirectory(parentID)
            guard size >= 0, (checksum?.utf8.count ?? 0) <= 256 else { throw NamespaceFailure.corrupt }
            guard try lookupUnchecked(parentID: parentID, name: name) == nil else { throw NamespaceFailure.collision }
            let exists = try database.query("SELECT 1 FROM nodes WHERE id=?"); defer { sqlite3_finalize(exists) }; database.bind(nodeID.uuidString, exists, 1)
            guard sqlite3_step(exists) == SQLITE_DONE else { throw NamespaceFailure.collision }
            let revision = try advanceRevision()
            try insertNode(id: nodeID, parent: parentID, name: name, kind: .file, size: size, modified: Date(), backing: nil)
            if nativeXattrs { try enableNewXattrs(id: nodeID, parent: parentID, name: name) }
            let base = try rawNode(nodeID)
            let n = try database.query("UPDATE nodes SET content_generation=1 WHERE id=?"); defer { sqlite3_finalize(n) }; database.bind(nodeID.uuidString, n, 1); try database.done(n)
            let content = try database.query("INSERT INTO content(node,generation,snapshot,size,checksum) VALUES(?,1,?,?,?)")
            defer { sqlite3_finalize(content) }; database.bind(nodeID.uuidString, content, 1); database.bind(snapshotID.uuidString, content, 2); database.bind(size, content, 3); database.bind(checksum, content, 4); try database.done(content)
            try touchParents([parentID], revision: revision)
            _ = try insertOperation(kind: .write, node: base, revision: revision, source: nil, destination: try pathUnchecked(nodeID), snapshot: snapshotID, checksum: checksum, operationID: operationID, requestDigest: signature)
            return try rawNode(nodeID)
        }
    }

    public func search(text: String, limit: Int = 100) throws -> [NamespaceNode] {
        try database.validate(); try ensureNotRestoring()
        guard (1...1000).contains(limit), text.utf8.count <= 256 else { throw NamespaceFailure.limitExceeded }
        let lower = Self.comparison(text), upper = Self.comparison(text) + "\u{10FFFF}"
        var result: [NamespaceNode] = [], afterName = lower, afterID = "", inspected = 0
        while result.count < limit {
            try Task.checkCancellation()
            let q = try database.query("SELECT id,comparison FROM nodes WHERE parent IS NOT NULL AND deleted IS NULL AND comparison>=? AND comparison<? AND (comparison>? OR (comparison=? AND id>?)) ORDER BY comparison,id LIMIT 512")
            database.bind(lower, q, 1); database.bind(upper, q, 2); database.bind(afterName, q, 3); database.bind(afterName, q, 4); database.bind(afterID, q, 5)
            var batch: [(UUID, String)] = []
            while true {
                let status = sqlite3_step(q); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)) else { sqlite3_finalize(q); throw NamespaceFailure.corrupt }
                batch.append((id, database.text(q, 1)))
            }
            sqlite3_finalize(q)
            guard !batch.isEmpty else { break }
            for (id, name) in batch {
                inspected += 1; guard inspected <= 50_000 else { throw NamespaceFailure.limitExceeded }
                let value = try rawNode(id)
                do { try assertVisible(value); if !(try isInTrash(value.id)) { result.append(value) } }
                catch NamespaceFailure.notFound { /* Hidden beneath a retained ancestor tombstone. */ }
                afterName = name; afterID = id.uuidString
                if result.count == limit { break }
            }
            if batch.count < 512 { break }
        }
        return result
    }

    @discardableResult public func updateMetadata(nodeID: NodeID, modifiedAt: Date, operationID: UUID? = nil) throws -> NamespaceOperation {
        guard modifiedAt.timeIntervalSince1970.isFinite else { throw NamespaceFailure.corrupt }
        let signature = try requestDigest(.init(kind: .metadata, node: nodeID, modifiedAt: modifiedAt))
        return try database.transaction {
            try ensureNotRestoring()
            if let previous = try replay(operationID, digest: signature) { return previous }
            let old = try rawNode(nodeID); try assertVisible(old)
            let revision = try advanceRevision()
            let q = try database.query("UPDATE nodes SET modified=?,metadata_generation=metadata_generation+1 WHERE id=?")
            defer { sqlite3_finalize(q) }; database.bind(modifiedAt.timeIntervalSince1970, q, 1); database.bind(nodeID.uuidString, q, 2); try database.done(q)
            return try insertOperation(kind: .metadata, node: old, revision: revision, source: try pathUnchecked(nodeID), destination: try pathUnchecked(nodeID), modifiedAt: modifiedAt, operationID: operationID, requestDigest: signature)
        }
    }

    // NULL means existing AppleDouble-backed metadata. An explicitly empty map
    // identifies a newly created item eligible for native metadata, even on restore.
    private func enableNewXattrs(id: UUID, parent: UUID, name: String) throws {
        guard try volumeUnchecked().mode == .managed, !name.hasPrefix("._"),
              try lookupUnchecked(parentID: parent, name: "._" + name) == nil else { return }
        let q = try database.query("UPDATE nodes SET xattrs=? WHERE id=?")
        defer { sqlite3_finalize(q) }
        database.bind(Data("{}".utf8), q, 1)
        database.bind(id.uuidString, q, 2)
        try database.done(q)
    }

    @discardableResult public func setXattr(nodeID: NodeID, name: String, value: Data?, policy: String, operationID: UUID) throws -> NamespaceOperation {
        guard try volume().mode == .managed, ManagedXattrs.names.contains(name) else { throw POSIXError(.ENOTSUP) }
        guard ["set", "create", "replace", "delete"].contains(policy), (value == nil) == (policy == "delete") else { throw POSIXError(.EINVAL) }
        if let value { try ManagedXattrs.validate([name: value]) }
        let digest = try requestDigest(.init(kind: .metadata, node: nodeID, name: name, checksum: value.map(CoreFileIO.hash), xattrPolicy: policy))
        return try database.transaction {
            try ensureNotRestoring()
            if let previous = try replay(operationID, digest: digest) { return previous }
            let old = try rawNode(nodeID)
            try assertVisible(old)
            guard var values = old.xattrs else { throw POSIXError(.ENOTSUP) }
            if policy == "create" && values[name] != nil { throw POSIXError(.EEXIST) }
            if (policy == "replace" || policy == "delete") && values[name] == nil { throw POSIXError(.ENOATTR) }
            values[name] = value
            try ManagedXattrs.validate(values)
            let revision = try advanceRevision()
            let q = try database.query("UPDATE nodes SET xattrs=?,metadata_generation=metadata_generation+1 WHERE id=?")
            defer { sqlite3_finalize(q) }
            database.bind(try JSONEncoder().encode(values), q, 1)
            database.bind(nodeID.uuidString, q, 2)
            try database.done(q)
            let path = try pathUnchecked(nodeID)
            return try insertOperation(kind: .metadata, node: old, revision: revision, source: path, destination: path,
                                       operationID: operationID, requestDigest: digest)
        }
    }

    /// Import is an explicit baseline operation. It cannot overwrite accepted local work.
    /// Pages are independently durable; unsupported names/collisions reject the entire page.
    public func importEntries(_ entries: [NamespaceImportEntry]) throws {
        guard entries.count <= 10_000 else { throw NamespaceFailure.limitExceeded }
        try database.transaction {
            try ensureNotRestoring()
            guard try database.scalar("SELECT count(*) FROM operations WHERE state!='complete'") == 0 else { throw NamespaceFailure.invalidTransition }
            let volume = try volumeUnchecked()
            guard !entries.isEmpty else { return }
            let revision = try advanceRevision()
            for entry in entries {
                guard entry.size >= 0, entry.modifiedAt.timeIntervalSince1970.isFinite, (entry.kind != .directory || entry.size == 0), !entry.path.hasPrefix("/"), !entry.path.hasSuffix("/") else { throw NamespaceFailure.invalidName }
                let components = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard !components.isEmpty, components.count <= 4096 else { throw NamespaceFailure.limitExceeded }
                if let backing = entry.backing { try Self.validateLocator(backing); guard backing.size == entry.size else { throw NamespaceFailure.corrupt } }
                var parent = volume.rootID
                for (offset, component) in components.enumerated() {
                    try Self.validateName(component)
                    let last = offset == components.count - 1
                    let kind: NamespaceNodeKind = last ? entry.kind : .directory
                    if let existing = try lookupUnchecked(parentID: parent, name: component) {
                        guard existing.name == component, existing.kind == kind else { throw NamespaceFailure.collision }
                        if last {
                            if existing.kind == .directory, existing.backing == nil, entry.size == 0 {
                                let update = try database.query("UPDATE nodes SET modified=?,backing=? WHERE id=?")
                                defer { sqlite3_finalize(update) }; database.bind(entry.modifiedAt.timeIntervalSince1970, update, 1)
                                database.bind(try entry.backing.map { try JSONEncoder().encode($0) }, update, 2); database.bind(existing.id.uuidString, update, 3); try database.done(update)
                                try insertHistory(try rawNode(existing.id), revision: revision)
                            } else { guard existing.size == entry.size, existing.backing == entry.backing else { throw NamespaceFailure.generationChanged } }
                        }
                        parent = existing.id
                    } else {
                        let id = UUID()
                        try insertNode(id: id, parent: parent, name: component, kind: kind, size: last ? entry.size : 0,
                                       modified: last ? entry.modifiedAt : Date(timeIntervalSince1970: 0), backing: last ? entry.backing : nil)
                        try insertEvent(nodeID: id, revision: revision, kind: .create)
                        parent = id
                    }
                }
            }
            if volume.mode == .compatible { try database.exec("UPDATE volume SET published=revision") }
        }
    }

    @discardableResult public func rename(nodeID: NodeID, parentID: NodeID, name: String, replace: Bool = false, operationID: UUID? = nil) throws -> NamespaceOperation {
        try database.transaction { try renameUnchecked(nodeID: nodeID, parentID: parentID, name: name, replace: replace, operationID: operationID) }
    }

    func renameUnchecked(nodeID: NodeID, parentID: NodeID, name: String, replace: Bool = false, operationID: UUID? = nil) throws -> NamespaceOperation {
        let signature = try requestDigest(.init(kind: .rename, node: nodeID, parent: parentID, name: name, replace: replace))
        try ensureNotRestoring()
        if let previous = try replay(operationID, digest: signature) { return previous }
        try Self.validateName(name); let old = try rawNode(nodeID); try assertVisible(old)
        let volume = try volumeUnchecked(); guard nodeID != volume.rootID else { throw NamespaceFailure.rootProtected }
        try assertDirectory(parentID)
        // Only ancestry is inspected. A move of 100,000 descendants updates one node.
        var ancestor: NodeID? = parentID; var visited = Set<NodeID>()
        while let id = ancestor {
            guard visited.insert(id).inserted, visited.count <= 4096, id != nodeID else { throw NamespaceFailure.cycle }
            ancestor = try rawNode(id).parentID
    }
    let source = try pathUnchecked(nodeID)
    let collision = try lookupUnchecked(parentID: parentID, name: name)
    if old.xattrs != nil, old.parentID != parentID || Self.comparison(old.name) != Self.comparison(name),
       try lookupUnchecked(parentID: parentID, name: "._" + name) != nil { throw NamespaceFailure.collision }
    if name.hasPrefix("._"), old.parentID != parentID || Self.comparison(name) != Self.comparison(old.name),
       let related = try lookupUnchecked(parentID: parentID, name: String(name.dropFirst(2))), related.xattrs != nil {
        throw NamespaceFailure.collision
    }
    var replaced: NodeID?
    if let target = collision, target.id != nodeID {
        guard replace else { throw NamespaceFailure.collision }
        guard target.kind == old.kind else { throw target.kind == .directory ? NamespaceFailure.isDirectory : NamespaceFailure.notDirectory }
        if target.kind == .directory, try hasChildren(target.id) { throw NamespaceFailure.directoryNotEmpty }
        // Regular-file publication is ordered behind earlier operations. Its
        // historical generation and validator fence the compatible overwrite.
        if target.kind == .directory, !(try pendingOperationIDs(nodeID: target.id)).isEmpty {
            throw POSIXError(.EBUSY)
        }
        replaced = target.id
    }
    let revision = try advanceRevision()
    if let replaced { try tombstone(replaced, revision: revision) }
    let q = try database.query("UPDATE nodes SET parent=?,name=?,comparison=?,metadata_generation=metadata_generation+1 WHERE id=?")
    defer { sqlite3_finalize(q) }; database.bind(parentID.uuidString, q, 1); database.bind(name, q, 2); database.bind(Self.comparison(name), q, 3)
    database.bind(nodeID.uuidString, q, 4); try database.done(q)
    try touchParents([old.parentID, parentID].compactMap { $0 }, revision: revision)
    return try insertOperation(kind: .rename, node: old, revision: revision, source: source, destination: try pathUnchecked(nodeID), replaced: replaced, operationID: operationID, requestDigest: signature)
    }

    @discardableResult public func remove(nodeID: NodeID, recursive: Bool = false, operationID: UUID? = nil) throws -> NamespaceOperation {
        try database.transaction { try removeUnchecked(nodeID: nodeID, recursive: recursive, operationID: operationID) }
    }
    /// Call only inside the owning namespace transaction.
    func removeUnchecked(nodeID: NodeID, recursive: Bool = false, operationID: UUID? = nil) throws -> NamespaceOperation {
        let signature = try requestDigest(.init(kind: .remove, node: nodeID, recursive: recursive))
        try ensureNotRestoring()
        if let previous = try replay(operationID, digest: signature) { return previous }
        let old = try rawNode(nodeID); try assertVisible(old)
        guard nodeID != (try volumeUnchecked().rootID) else { throw NamespaceFailure.rootProtected }
        if old.kind == .directory && !recursive { if try hasChildren(nodeID) { throw NamespaceFailure.directoryNotEmpty } }
        let source = try pathUnchecked(nodeID), revision = try advanceRevision()
        try tombstone(nodeID, revision: revision)
        if let parent = old.parentID { try touchParents([parent], revision: revision) }
        return try insertOperation(kind: .remove, node: old, revision: revision, source: source, destination: nil, operationID: operationID, requestDigest: signature)
    }

    public func resolvedPath(_ nodeID: NodeID) throws -> String { try database.validate(); try ensureNotRestoring(); let n = try rawNode(nodeID); try assertVisible(n); return try pathUnchecked(nodeID) }
    /// The physical locator belongs to the content generation, not the displayed path.
    public func resolvedLocator(_ nodeID: NodeID) throws -> ObjectLocator? { try node(nodeID).backing }

    @discardableResult public func commitContent(nodeID: NodeID, expectedGeneration: Int64, newSize: Int64, stagedSnapshotID: UUID, checksum: String? = nil, operationID: UUID? = nil, allowUnlinked: Bool = false, mutationFingerprint: String? = nil, bufferBytes: Int = 0) throws -> NamespaceOperation {
        let signature = try requestDigest(.init(kind: .write, node: nodeID, expectedGeneration: expectedGeneration, newSize: newSize, snapshot: stagedSnapshotID, checksum: checksum, allowUnlinked: allowUnlinked))
        return try database.transaction(bufferBytes: bufferBytes) {
            try ensureNotRestoring()
            if let previous = try replay(operationID, digest: signature) { return previous }
            let old = try rawNode(nodeID)
            var localOnly = false
            do { try assertVisible(old) }
            catch NamespaceFailure.notFound { guard allowUnlinked else { throw NamespaceFailure.notFound }; localOnly = true }
            guard old.kind == .file else { throw NamespaceFailure.isDirectory }
            guard old.contentGeneration == expectedGeneration, old.contentGeneration < Int64.max else { throw NamespaceFailure.generationChanged }
            guard newSize >= 0, checksum == nil || checksum!.utf8.count <= 256 else { throw NamespaceFailure.corrupt }
            let revision = try advanceRevision()
            let q = try database.query("UPDATE nodes SET size=?,content_generation=content_generation+1,metadata_generation=metadata_generation+1,modified=? WHERE id=?")
            defer { sqlite3_finalize(q) }; database.bind(newSize, q, 1); database.bind(Date().timeIntervalSince1970, q, 2); database.bind(nodeID.uuidString, q, 3); try database.done(q)
            let content = try database.query("INSERT INTO content(node,generation,snapshot,size,checksum) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(content) }; database.bind(nodeID.uuidString, content, 1); database.bind(expectedGeneration + 1, content, 2); database.bind(stagedSnapshotID.uuidString, content, 3); database.bind(newSize, content, 4); database.bind(checksum, content, 5); try database.done(content)
            let operation = try insertOperation(kind: .write, node: old, revision: revision, source: try pathUnchecked(nodeID), destination: try pathUnchecked(nodeID), snapshot: stagedSnapshotID, checksum: checksum, operationID: operationID, requestDigest: signature, localOnly: localOnly)
            if let mutationFingerprint {
                try insertReceipt(operationID: operation.id, stepID: "mutation-fingerprint", validator: mutationFingerprint)
            }
            return operation
        }
    }

    public func markContentPublished(nodeID: NodeID, generation: Int64, backing: ObjectLocator) throws {
        try database.transaction {
            try Self.validateLocator(backing); let n = try rawNode(nodeID)
            guard n.contentGeneration == generation, n.size == backing.size else { throw NamespaceFailure.generationChanged }
            try recordPublishedContentUnchecked(nodeID: nodeID, generation: generation, backing: backing, updateCurrent: true)
        }
    }

    private static let nodeColumns = "inode,parent,name,kind,size,content_generation,metadata_generation,modified,deleted,backing,(SELECT snapshot FROM content WHERE node=nodes.id AND generation=nodes.content_generation AND published=0),xattrs"

    func rawNode(_ id: NodeID) throws -> NamespaceNode {
        let q = try database.query("SELECT \(Self.nodeColumns) FROM nodes WHERE id=?")
        defer { sqlite3_finalize(q) }; database.bind(id.uuidString, q, 1)
        guard sqlite3_step(q) == SQLITE_ROW else { throw NamespaceFailure.notFound }
        return try decodeNode(q, id: id)
    }
    private func decodeNode(_ q: OpaquePointer, id: NodeID) throws -> NamespaceNode {
        guard let kind = NamespaceNodeKind(rawValue: database.text(q, 3)) else { throw NamespaceFailure.corrupt }
        let parent: UUID? = sqlite3_column_type(q, 1) == SQLITE_NULL ? nil : UUID(uuidString: database.text(q, 1))
        let backing = sqlite3_column_type(q, 9) == SQLITE_NULL ? nil : try JSONDecoder().decode(ObjectLocator.self, from: database.data(q, 9))
        return NamespaceNode(id: id, inode: sqlite3_column_int64(q, 0), parentID: parent, name: database.text(q, 2), kind: kind,
                             size: sqlite3_column_int64(q, 4), contentGeneration: sqlite3_column_int64(q, 5), metadataGeneration: sqlite3_column_int64(q, 6),
                             modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(q, 7)), deletedRevision: sqlite3_column_type(q, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(q, 8), backing: backing, stagedSnapshotID: sqlite3_column_type(q, 10) == SQLITE_NULL ? nil : UUID(uuidString: database.text(q, 10)),
                             xattrs: sqlite3_column_type(q, 11) == SQLITE_NULL ? nil : try JSONDecoder().decode([String: Data].self, from: database.data(q, 11)))
    }
    func assertVisible(_ node: NamespaceNode) throws {
        var current = node; var seen = Set<UUID>()
        while true {
            guard current.deletedRevision == nil else { throw NamespaceFailure.notFound }
            guard seen.insert(current.id).inserted, seen.count <= 4096 else { throw NamespaceFailure.corrupt }
            guard let parent = current.parentID else { break }; current = try rawNode(parent)
        }
    }
    func assertDirectory(_ id: NodeID) throws { let n = try rawNode(id); try assertVisible(n); guard n.kind == .directory else { throw NamespaceFailure.notDirectory } }
    func pathUnchecked(_ id: NodeID) throws -> String {
        var current = try rawNode(id), names: [String] = [], seen = Set<UUID>()
        while let parent = current.parentID {
            guard seen.insert(current.id).inserted, seen.count <= 4096 else { throw NamespaceFailure.corrupt }
            names.append(current.name); current = try rawNode(parent)
        }
        return names.reversed().joined(separator: "/")
    }
    func hasChildren(_ id: UUID) throws -> Bool {
        let q = try database.query("SELECT 1 FROM nodes WHERE parent=? AND deleted IS NULL LIMIT 1"); defer { sqlite3_finalize(q) }
        database.bind(id.uuidString, q, 1); return sqlite3_step(q) == SQLITE_ROW
    }
    func touchParents(_ parents: [UUID], revision: Int64) throws {
        for id in Set(parents) {
            let q = try database.query("UPDATE nodes SET modified=?,metadata_generation=metadata_generation+1 WHERE id=?")
            defer { sqlite3_finalize(q) }; database.bind(Date().timeIntervalSince1970, q, 1); database.bind(id.uuidString, q, 2); try database.done(q)
            try insertEvent(nodeID: id, revision: revision, kind: .metadata)
        }
    }
    func tombstone(_ id: UUID, revision: Int64) throws {
        let q = try database.query("UPDATE nodes SET deleted=?,metadata_generation=metadata_generation+1 WHERE id=?"); defer { sqlite3_finalize(q) }
        database.bind(revision, q, 1); database.bind(id.uuidString, q, 2); try database.done(q)
    }
    func advanceRevision() throws -> Int64 {
        try ensureHistoryBaseline()
        try database.exec("UPDATE volume SET revision=revision+1 WHERE revision<9223372036854775807")
        guard sqlite3_changes(database.db) == 1 else { throw NamespaceFailure.limitExceeded }
        return try database.scalar("SELECT revision FROM volume")
    }
    func insertNode(id: UUID, parent: UUID, name: String, kind: NamespaceNodeKind, size: Int64, modified: Date, backing: ObjectLocator?) throws {
        let inode = try database.scalar("SELECT next_inode FROM volume")
        guard inode > 2 && inode < Int64.max else { throw NamespaceFailure.limitExceeded }
        try database.exec("UPDATE volume SET next_inode=next_inode+1")
        let q = try database.query("INSERT INTO nodes(id,inode,parent,name,comparison,kind,size,modified,backing) VALUES(?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(q) }; database.bind(id.uuidString, q, 1); database.bind(inode, q, 2); database.bind(parent.uuidString, q, 3)
        database.bind(name, q, 4); database.bind(Self.comparison(name), q, 5); database.bind(kind.rawValue, q, 6); database.bind(size, q, 7); database.bind(modified.timeIntervalSince1970, q, 8)
        database.bind(try backing.map { try JSONEncoder().encode($0) }, q, 9); try database.done(q)
        if kind == .file, let backing { try recordPublishedContentUnchecked(nodeID: id, generation: 0, backing: backing, updateCurrent: false) }
        try insertHistory(try rawNode(id), revision: try database.scalar("SELECT revision FROM volume"))
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.utf8.contains(0) else { throw NamespaceFailure.invalidName }
    }
    static func comparison(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func validateLocator(_ locator: ObjectLocator) throws {
        guard !locator.key.isEmpty, locator.key.utf8.count <= 1024, !locator.key.utf8.contains(0), locator.size >= 0,
              (locator.validator?.utf8.count ?? 0) <= 4096, (locator.checksum?.utf8.count ?? 0) <= 256 else { throw NamespaceFailure.corrupt }
    }
}

/// Internal only: the actor is the single SQLite executor. Advisory ownership and inode
/// checks prevent a second writer or a replaced store from being silently adopted.
final class NamespaceDatabase: @unchecked Sendable {
    var db: OpaquePointer?
    private let directory: URL
    private var lockFD: Int32 = -1
    private var directoryID: (dev_t, ino_t)?
    private var databaseID: (dev_t, ino_t)?
    private var lockID: (dev_t, ino_t)?
    private(set) var supportsAdmissionFence = false
    private var pendingMediaFence = false
    private var restoreSQLiteFence = false
    private var openWriteBytes = 0
    private var nextSeal = ContinuousClock.now
    static let writeWindow = 8 * 1024 * 1024
    private static let writeSignposts = OSSignposter(subsystem: "local.bucketdrive.engine", category: "FinderWrite")
    var needsIdleSeal: Bool { openWriteBytes > 0 && ContinuousClock.now >= nextSeal }
    var admissionBarrier: (Int32) throws -> Void = CoreFileIO.requireMediaBarrier
    var beforeCommitForTesting: (() throws -> Void)?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL, binding: String, mode: NamespaceStorageMode, volumeID: UUID?, rootID: UUID?) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var dir = stat()
        guard lstat(directory.path, &dir) == 0, dir.st_mode & S_IFMT == S_IFDIR, dir.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw NamespaceFailure.storage }
        let lockPath = directory.appendingPathComponent("owner.lock").path
        lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw NamespaceFailure.ownership }
        do {
            var lock = stat()
            guard fstat(lockFD, &lock) == 0, lock.st_mode & S_IFMT == S_IFREG, lock.st_uid == getuid(), lock.st_nlink == 1,
                  fchmod(lockFD, 0o600) == 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw NamespaceFailure.ownership }
            lockID = (lock.st_dev, lock.st_ino)
            let path = directory.appendingPathComponent("namespace.sqlite").path
            for suffix in ["", "-journal", "-wal", "-shm"] {
                var file = stat()
                if lstat(path + suffix, &file) == 0 {
                    guard file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1,
                          chmod(path + suffix, 0o600) == 0 else { throw NamespaceFailure.storage }
                } else if errno != ENOENT { throw NamespaceFailure.storage }
            }
            let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NamespaceFailure.storage }
            defer { Darwin.close(fd) }; var initial = stat(); guard fstat(fd, &initial) == 0 else { throw NamespaceFailure.storage }
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw NamespaceFailure.storage }
            sqlite3_busy_timeout(db, 1000)
            try exec("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON")
            let version = try scalar("PRAGMA user_version")
            guard (0...7).contains(version) else { throw NamespaceFailure.incompatibleSchema }
            // Switching a SQLite file to WAL changes its persistent header. Check
            // schema and drive ownership before changing any on-disk setting.
            if version == 0 {
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else { throw NamespaceFailure.incompatibleSchema }
            } else {
                try validateVolumeIdentity(binding: binding, mode: mode, volumeID: volumeID, rootID: rootID)
                if version < 4, try scalar("SELECT EXISTS(SELECT 1 FROM operations LIMIT 1)") != 0 {
                    throw NamespaceFailure.incompatibleSchema
                }
            }
            // A normal close checkpoints WAL; crash recovery replays its frames.
            // Use SQLite backup for a live store, or copy its directory after close.
            let journalMode = mode == .managed ? "WAL" : "DELETE"
            try exec("PRAGMA journal_mode=\(journalMode); PRAGMA wal_autocheckpoint=512; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON; PRAGMA max_page_count=1048576")
            if version == 0 {
                try exec("BEGIN IMMEDIATE")
                do {
                    try exec("""
                    CREATE TABLE volume(id TEXT PRIMARY KEY,root TEXT NOT NULL,binding TEXT NOT NULL,mode TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,published INTEGER NOT NULL DEFAULT 0,next_inode INTEGER NOT NULL DEFAULT 3);
                    CREATE TABLE nodes(id TEXT PRIMARY KEY,inode INTEGER NOT NULL UNIQUE,parent TEXT REFERENCES nodes(id),name TEXT NOT NULL,comparison TEXT NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('file','directory')),size INTEGER NOT NULL CHECK(size>=0),content_generation INTEGER NOT NULL DEFAULT 0,metadata_generation INTEGER NOT NULL DEFAULT 0,modified REAL NOT NULL,deleted INTEGER,backing BLOB);
                    CREATE UNIQUE INDEX live_names ON nodes(parent,comparison) WHERE deleted IS NULL;
                    CREATE INDEX children ON nodes(parent,id) WHERE deleted IS NULL;
                    CREATE TABLE content(node TEXT NOT NULL REFERENCES nodes(id),generation INTEGER NOT NULL,snapshot TEXT NOT NULL,size INTEGER NOT NULL,checksum TEXT,published INTEGER NOT NULL DEFAULT 0,locator BLOB,PRIMARY KEY(node,generation));
                    CREATE TABLE operations(id TEXT PRIMARY KEY,sequence INTEGER NOT NULL UNIQUE,node TEXT NOT NULL REFERENCES nodes(id),kind TEXT NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,error TEXT,payload BLOB NOT NULL);
                    CREATE INDEX pending_operations ON operations(state,sequence);
                    CREATE TABLE dependencies(operation TEXT NOT NULL REFERENCES operations(id),dependency TEXT NOT NULL REFERENCES operations(id),PRIMARY KEY(operation,dependency));
                    CREATE TABLE receipts(operation TEXT NOT NULL REFERENCES operations(id),step TEXT NOT NULL,validator TEXT,recorded REAL NOT NULL,PRIMARY KEY(operation,step));
                    CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,node TEXT NOT NULL REFERENCES nodes(id),revision INTEGER NOT NULL,kind TEXT NOT NULL);
                    PRAGMA user_version=1;
                    """)
                    let root = rootID ?? UUID(), id = volumeID ?? UUID()
                    let v = try query("INSERT INTO volume(id,root,binding,mode) VALUES(?,?,?,?)"); defer { sqlite3_finalize(v) }
                    bind(id.uuidString, v, 1); bind(root.uuidString, v, 2); bind(binding, v, 3); bind(mode.rawValue, v, 4); try done(v)
                    let n = try query("INSERT INTO nodes(id,inode,parent,name,comparison,kind,size,modified) VALUES(?,2,NULL,'','','directory',0,0)"); defer { sqlite3_finalize(n) }; bind(root.uuidString, n, 1); try done(n)
                    try exec("COMMIT")
                } catch { try? exec("ROLLBACK"); throw error }
            }
            if version < 2 {
                try exec("CREATE INDEX IF NOT EXISTS name_search ON nodes(comparison,id) WHERE deleted IS NULL; PRAGMA user_version=2;")
            }
            if version < 3 {
                try exec("CREATE TABLE IF NOT EXISTS restore_session(volume TEXT NOT NULL,root TEXT NOT NULL,revision INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS restore_nodes(id TEXT PRIMARY KEY,payload BLOB NOT NULL); PRAGMA user_version=3;")
            }
            if version < 4 {
                try exec("CREATE TABLE IF NOT EXISTS node_history(node TEXT NOT NULL,revision INTEGER NOT NULL,parent TEXT,deleted INTEGER NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(node,revision)); CREATE INDEX IF NOT EXISTS historical_children ON node_history(parent,node,revision); PRAGMA user_version=4;")
            }
            if version < 5 {
                try exec("BEGIN IMMEDIATE")
                do {
                    try exec("CREATE TABLE namespace_names(node TEXT PRIMARY KEY REFERENCES nodes(id),name TEXT NOT NULL); CREATE VIRTUAL TABLE namespace_terms USING fts5(name,content='namespace_names',content_rowid='rowid',tokenize='unicode61',prefix='2 3 4'); INSERT INTO namespace_names(node,name) SELECT id,name FROM nodes WHERE deleted IS NULL AND parent IS NOT NULL; INSERT INTO namespace_terms(namespace_terms) VALUES('rebuild'); PRAGMA user_version=5; COMMIT;")
                } catch { try? exec("ROLLBACK"); throw error }
            }
            if version < 6 { try exec("CREATE TABLE namespace_publications(revision INTEGER PRIMARY KEY,validator TEXT NOT NULL); PRAGMA user_version=6;") }
            if version < 7 {
                try exec("BEGIN IMMEDIATE")
                do { try exec("ALTER TABLE nodes ADD COLUMN xattrs BLOB; PRAGMA user_version=7; COMMIT") }
                catch { try? exec("ROLLBACK"); throw error }
            }
            try exec("CREATE INDEX IF NOT EXISTS operations_node ON operations(node,state,sequence)")
            try validateVolumeIdentity(binding: binding, mode: mode, volumeID: volumeID, rootID: rootID)
            let check = try query("PRAGMA quick_check"); defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, text(check, 0) == "ok" else { throw NamespaceFailure.corrupt }
            var actual = stat()
            guard lstat(path, &actual) == 0, actual.st_dev == initial.st_dev, actual.st_ino == initial.st_ino else { throw NamespaceFailure.storage }
            directoryID = (dir.st_dev, dir.st_ino); databaseID = (actual.st_dev, actual.st_ino)
            let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw NamespaceFailure.storage }; defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw NamespaceFailure.storage }
            try validate()
            if mode == .managed, CoreFileIO.sameAPFSVolume(directory, URL(fileURLWithPath: path)) {
                do {
                    try CoreFileIO.requireOrderingBarrier(lockFD)
                    try CoreFileIO.requireMediaBarrier(lockFD)
                    supportsAdmissionFence = true
                }
                catch let error as POSIXError where error.code == .ENOTSUP { }
                if supportsAdmissionFence {
                    // Recover unclosed writes left in the kernel by a killed
                    // previous owner before exposing any recovered namespace.
                    openWriteBytes = 1
                    try sealOpenWrites()
                }
            }
        } catch { sqlite3_close(db); db = nil; if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }; throw error }
    }
    private func validateVolumeIdentity(binding: String, mode: NamespaceStorageMode, volumeID: UUID?, rootID: UUID?) throws {
        let v = try query("SELECT binding,mode,id,root FROM volume"); defer { sqlite3_finalize(v) }
        guard sqlite3_step(v) == SQLITE_ROW, text(v, 0) == binding else { throw NamespaceFailure.bindingMismatch }
        guard text(v, 1) == mode.rawValue else { throw NamespaceFailure.incompatibleSchema }
        if let volumeID { guard text(v, 2) == volumeID.uuidString else { throw NamespaceFailure.bindingMismatch } }
        if let rootID { guard text(v, 3) == rootID.uuidString else { throw NamespaceFailure.bindingMismatch } }
    }
    deinit { sqlite3_close(db); if lockFD >= 0 { Darwin.close(lockFD) } }
    func close() { sqlite3_close(db); db = nil; if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 } }
    func validate() throws {
        var dir = stat(), file = stat(), lock = stat(), held = stat()
        guard let d = directoryID, let f = databaseID, let l = lockID,
              lstat(directory.path, &dir) == 0, dir.st_mode & S_IFMT == S_IFDIR, dir.st_uid == getuid(), dir.st_mode & 0o077 == 0,
              lstat(directory.appendingPathComponent("namespace.sqlite").path, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1, file.st_mode & 0o077 == 0,
              lstat(directory.appendingPathComponent("owner.lock").path, &lock) == 0, lock.st_mode & S_IFMT == S_IFREG, lock.st_uid == getuid(), lock.st_nlink == 1,
              fstat(lockFD, &held) == 0, dir.st_dev == d.0, dir.st_ino == d.1, file.st_dev == f.0, file.st_ino == f.1,
              lock.st_dev == l.0, lock.st_ino == l.1, held.st_dev == l.0, held.st_ino == l.1 else { throw NamespaceFailure.storage }
        for suffix in ["-journal", "-wal", "-shm"] {
            var sidecar = stat()
            if lstat(directory.appendingPathComponent("namespace.sqlite" + suffix).path, &sidecar) == 0 {
                guard sidecar.st_mode & S_IFMT == S_IFREG, sidecar.st_uid == getuid(), sidecar.st_nlink == 1 else { throw NamespaceFailure.storage }
            } else if errno != ENOENT { throw NamespaceFailure.storage }
        }
        try finishFence()
    }
    /// Normal commits use SQLite FULL durability. An opted-in open Finder file
    /// may accumulate at most 8 MiB of ordered WAL commits before a full device
    /// flush. New-file close, fsync, detach and remote publication all call seal.
    func transaction<T>(bufferBytes: Int = 0, _ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try validate()
        guard (0...Self.writeWindow).contains(bufferBytes), bufferBytes == 0 || supportsAdmissionFence else { throw NamespaceFailure.storage }
        if openWriteBytes > 0 && (bufferBytes == 0 || openWriteBytes > Self.writeWindow - bufferBytes || ContinuousClock.now >= nextSeal) {
            try sealOpenWrites()
        }
        let buffered = bufferBytes > 0
        do {
            // WAL NORMAL still commits to the kernel before returning, allowing
            // process-crash recovery. A full fence below is required to survive
            // sudden loss of power. Keep all other transactions at their settings.
            if buffered { try exec("PRAGMA synchronous=NORMAL; PRAGMA fullfsync=OFF") }
            try exec("BEGIN IMMEDIATE")
            let result = try body()
            try Task.checkCancellation()
            try beforeCommitForTesting?()
            try validate()
            if buffered {
                // Even if the WAL frame survives an abrupt power cut, every
                // referenced immutable file and its published name precede it.
                do { try CoreFileIO.requireOrderingBarrier(lockFD) }
                catch let error as POSIXError where error.code == .ENOTSUP { try CoreFileIO.requireMediaBarrier(lockFD) }
            }
            try exec("COMMIT")
            if buffered {
                if openWriteBytes == 0 { nextSeal = .now.advanced(by: .milliseconds(250)) }
                openWriteBytes += bufferBytes
            }
            restoreSQLiteFence = buffered
            pendingMediaFence = openWriteBytes >= Self.writeWindow
            try finishFence()
            return result
        } catch {
            try? exec("ROLLBACK")
            if buffered { restoreSQLiteFence = true }
            throw error
        }
    }

    func sealOpenWrites() throws {
        if openWriteBytes > 0 { pendingMediaFence = true }
        try finishFence()
    }

    private func finishFence() throws {
        if restoreSQLiteFence {
            try exec("PRAGMA synchronous=FULL; PRAGMA fullfsync=ON")
            restoreSQLiteFence = false
        }
        guard pendingMediaFence else { return }
        // NORMAL may leave a WAL commit in the kernel. Queue both SQLite files
        // and their names before flushing the device. Keep the latch on every
        // failure: no reader, retry or publisher may bypass a failed seal.
        if openWriteBytes > 0 {
            // A second POSIX open/close of a SQLite file could drop this
            // process's advisory locks. Flush the owning VFS handles in place.
            for opcode in [SQLITE_FCNTL_FILE_POINTER, SQLITE_FCNTL_JOURNAL_POINTER] {
                var file: UnsafeMutablePointer<sqlite3_file>?
                guard sqlite3_file_control(db, "main", opcode, &file) == SQLITE_OK else { throw NamespaceFailure.storage }
                if file == nil, opcode == SQLITE_FCNTL_JOURNAL_POINTER { continue }
                guard let file, let sync = file.pointee.pMethods?.pointee.xSync,
                      sync(file, SQLITE_SYNC_NORMAL) == SQLITE_OK else { throw NamespaceFailure.storage }
            }
            try CoreFileIO.syncDirectory(directory)
        }
        try admissionBarrier(lockFD)
        Self.writeSignposts.emitEvent("OpenWriteSeal", "bytes=\(self.openWriteBytes, privacy: .public)")
        pendingMediaFence = false
        openWriteBytes = 0
    }
    func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NamespaceFailure.storage } }
    func query(_ sql: String) throws -> OpaquePointer {
        var q: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &q, nil) == SQLITE_OK, let q else { throw NamespaceFailure.storage }; return q
    }
    func scalar(_ sql: String) throws -> Int64 { let q = try query(sql); defer { sqlite3_finalize(q) }; guard sqlite3_step(q) == SQLITE_ROW else { throw NamespaceFailure.storage }; return sqlite3_column_int64(q, 0) }
    func text(_ q: OpaquePointer, _ i: Int32) -> String { guard let p = sqlite3_column_text(q, i) else { return "" }; return String(cString: p) }
    func data(_ q: OpaquePointer, _ i: Int32) -> Data { guard let p = sqlite3_column_blob(q, i) else { return Data() }; return Data(bytes: p, count: Int(sqlite3_column_bytes(q, i))) }
    func bind(_ value: String?, _ q: OpaquePointer, _ i: Int32) { if let value { sqlite3_bind_text(q, i, value, -1, transient) } else { sqlite3_bind_null(q, i) } }
    func bind(_ value: Data?, _ q: OpaquePointer, _ i: Int32) { if let value { _ = value.withUnsafeBytes { sqlite3_bind_blob(q, i, $0.baseAddress, Int32($0.count), transient) } } else { sqlite3_bind_null(q, i) } }
    func bind(_ value: Int64, _ q: OpaquePointer, _ i: Int32) { sqlite3_bind_int64(q, i, value) }
    func bind(_ value: Double, _ q: OpaquePointer, _ i: Int32) { sqlite3_bind_double(q, i, value) }
    func done(_ q: OpaquePointer) throws { guard sqlite3_step(q) == SQLITE_DONE else { throw NamespaceFailure.storage } }
}
