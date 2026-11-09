import Foundation
import SQLite3

public struct NamespaceTrashEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let node: NamespaceNode
    public let originalParentID: UUID
    public let deletedAt: Date
}

extension NamespaceStore {
    /// Ordinary retained nodes, not tombstones: sync, range readers and GC keep
    /// their normal generation protection. The portable wrapper preserves the
    /// original name, parent identity and deletion time through managed recovery.
    public static let trashDirectoryName = ".bucketdrive-trash-v1"

    public func moveToTrash(nodeID: UUID, operationID: UUID) throws -> NamespaceTrashEntry {
        try database.transaction {
            try ensureNotRestoring()
            if let prior = try operationUnchecked(operationID) {
                guard prior.kind == .rename, prior.nodeID == nodeID,
                      let destination = prior.destinationPath else { throw NamespaceFailure.invalidTransition }
                let parts = destination.split(separator: "/")
                guard parts.count == 3, parts[0] == Self.trashDirectoryName,
                      let wrapper = try lookupUnchecked(parentID: volumeUnchecked().rootID, name: Self.trashDirectoryName),
                      let container = try lookupUnchecked(parentID: wrapper.id, name: String(parts[1])),
                      let parsed = Self.parseTrashContainer(container) else { throw NamespaceFailure.invalidTransition }
                return NamespaceTrashEntry(id: container.id, node: try rawNode(nodeID), originalParentID: parsed.0, deletedAt: parsed.1)
            }
            let old = try rawNode(nodeID); try assertVisible(old)
            guard let originalParent = old.parentID, !(try isInTrash(nodeID)) else { throw NamespaceFailure.rootProtected }
            let root = try volumeUnchecked().rootID
            let trash: NamespaceNode
            if let existing = try lookupUnchecked(parentID: root, name: Self.trashDirectoryName) {
                guard existing.kind == .directory else { throw NamespaceFailure.collision }; trash = existing
            } else { trash = try createTrashDirectory(parent: root, name: Self.trashDirectoryName) }
            let deletedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let containerName = "\(Int64(deletedAt.timeIntervalSince1970))_\(originalParent.uuidString)_\(operationID.uuidString)"
            let container = try createTrashDirectory(parent: trash.id, name: containerName)
            _ = try renameUnchecked(nodeID: nodeID, parentID: container.id, name: old.name, operationID: operationID)
            return NamespaceTrashEntry(id: container.id, node: try rawNode(nodeID), originalParentID: originalParent, deletedAt: deletedAt)
        }
    }

    /// Pagination is by wrapper ID, not deletion date, so new arrivals cannot
    /// make an already-returned page skip or repeat existing entries.
    public func trashEntries(after: String? = nil, limit: Int = 200) throws -> (entries: [NamespaceTrashEntry], next: String?) {
        try database.validate(); try ensureNotRestoring()
        guard let root = try lookupUnchecked(parentID: volumeUnchecked().rootID, name: Self.trashDirectoryName) else { return ([], nil) }
        let page = try list(parentID: root.id, after: after, limit: limit)
        var entries: [NamespaceTrashEntry] = []
        for container in page.nodes {
            guard let parsed = Self.parseTrashContainer(container) else { continue }
            let children = try list(parentID: container.id, limit: 2)
            // Foreign/malformed containers are never selected for automatic action.
            guard children.nodes.count == 1, children.next == nil, let node = children.nodes.first else { continue }
            entries.append(.init(id: container.id, node: node, originalParentID: parsed.0, deletedAt: parsed.1))
        }
        return (entries, page.next)
    }

    public func restoreFromTrash(containerID: UUID, parentID: UUID? = nil, name: String? = nil, operationID: UUID) throws -> NamespaceNode {
        try database.transaction {
            try ensureNotRestoring()
            let container = try rawNode(containerID)
            guard let parsed = Self.parseTrashContainer(container),
                  let parent = container.parentID,
                  let trash = try lookupUnchecked(parentID: volumeUnchecked().rootID, name: Self.trashDirectoryName), parent == trash.id else { throw NamespaceFailure.notFound }
            struct RestoreRequest: Encodable { let container: UUID; let parent: UUID?; let name: String? }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fingerprint = CoreFileIO.hash(try encoder.encode(RestoreRequest(container: containerID, parent: parentID, name: name)))
            if let prior = try operationUnchecked(operationID) {
                let q = try database.query("SELECT validator FROM receipts WHERE operation=? AND step='trash-restore-request'")
                defer { sqlite3_finalize(q) }; database.bind(operationID.uuidString, q, 1)
                guard prior.kind == .rename, prior.sourcePath?.hasPrefix(Self.trashDirectoryName + "/" + container.name + "/") == true,
                      sqlite3_step(q) == SQLITE_ROW, database.text(q, 0) == fingerprint else { throw NamespaceFailure.invalidTransition }
                return try rawNode(prior.nodeID)
            }
            try assertVisible(container)
            let children = try list(parentID: containerID, limit: 2)
            guard children.nodes.count == 1, children.next == nil, let node = children.nodes.first else { throw NamespaceFailure.notFound }
            let destination: UUID
            if let parentID { destination = parentID }
            else if let oldParent = try? self.node(parsed.0), oldParent.kind == .directory, !(try isInTrash(oldParent.id)) { destination = oldParent.id }
            else { destination = try volumeUnchecked().rootID }
            guard !(try isInTrash(destination)) else { throw NamespaceFailure.invalidTransition }
            _ = try renameUnchecked(nodeID: node.id, parentID: destination, name: name ?? node.name, operationID: operationID)
            let receipt = try database.query("INSERT INTO receipts(operation,step,validator,recorded) VALUES(?,'trash-restore-request',?,?)")
            defer { sqlite3_finalize(receipt) }; database.bind(operationID.uuidString, receipt, 1)
            database.bind(fingerprint, receipt, 2); database.bind(Date().timeIntervalSince1970, receipt, 3); try database.done(receipt)
            // Queue cleanup after the restore rename in this same transaction.
            // The retained tombstoned row still binds replay; remote deletion waits
            // for the rename's durable dependency and cannot race its source copy.
            _ = try removeUnchecked(nodeID: containerID)
            return try rawNode(node.id)
        }
    }

    /// Explicit removal from Recently Deleted and the current namespace. Existing
    /// open generations and remote recovery/history objects retain their safety
    /// protections; this does not promise physical erasure of every remote version.
    public func purgeTrash(containerID: UUID, operationID: UUID) throws -> NamespaceOperation {
        try database.transaction {
            try ensureNotRestoring()
            let fingerprint = CoreFileIO.hash(Data(("purgeTrash-v1:" + containerID.uuidString).utf8))
            if let prior = try operationUnchecked(operationID) {
                let q = try database.query("SELECT validator FROM receipts WHERE operation=? AND step='trash-purge-request'")
                defer { sqlite3_finalize(q) }; database.bind(operationID.uuidString, q, 1)
                guard prior.kind == .remove, prior.nodeID == containerID,
                      sqlite3_step(q) == SQLITE_ROW, database.text(q, 0) == fingerprint else { throw NamespaceFailure.invalidTransition }
                return prior
            }
            let container = try rawNode(containerID); try assertVisible(container)
            guard Self.parseTrashContainer(container) != nil,
                  let trash = try lookupUnchecked(parentID: volumeUnchecked().rootID, name: Self.trashDirectoryName),
                  container.parentID == trash.id else { throw NamespaceFailure.notFound }
            let children = try list(parentID: containerID, limit: 2)
            guard children.nodes.count == 1, children.next == nil else { throw NamespaceFailure.invalidTransition }
            let operation = try removeUnchecked(nodeID: containerID, recursive: true, operationID: operationID)
            let q = try database.query("INSERT INTO receipts(operation,step,validator,recorded) VALUES(?,'trash-purge-request',?,?)")
            defer { sqlite3_finalize(q) }; database.bind(operationID.uuidString, q, 1); database.bind(fingerprint, q, 2)
            database.bind(Date().timeIntervalSince1970, q, 3); try database.done(q)
            return operation
        }
    }

    func isInTrash(_ id: UUID) throws -> Bool {
        let root = try volumeUnchecked().rootID
        var current = try rawNode(id), seen = Set<UUID>()
        while current.id != root {
            guard seen.insert(current.id).inserted, seen.count <= 4096 else { throw NamespaceFailure.cycle }
            if current.parentID == root && current.name == Self.trashDirectoryName { return true }
            guard let parent = current.parentID else { throw NamespaceFailure.corrupt }
            current = try rawNode(parent)
        }
        return false
    }
    private func createTrashDirectory(parent: UUID, name: String) throws -> NamespaceNode {
        guard try lookupUnchecked(parentID: parent, name: name) == nil else { throw NamespaceFailure.collision }
        let revision = try advanceRevision(), id = UUID()
        try insertNode(id: id, parent: parent, name: name, kind: .directory, size: 0, modified: Date(), backing: nil)
        try touchParents([parent], revision: revision)
        let node = try rawNode(id)
        let signature = try requestDigest(.init(kind: .create, parent: parent, name: name, nodeKind: .directory))
        _ = try insertOperation(kind: .create, node: node, revision: revision, source: nil, destination: try pathUnchecked(id), requestDigest: signature)
        return node
    }
    private static func parseTrashContainer(_ node: NamespaceNode) -> (UUID, Date)? {
        let parts = node.name.split(separator: "_")
        guard node.kind == .directory, parts.count == 3, let seconds = Int64(parts[0]), seconds > 0,
              let parent = UUID(uuidString: String(parts[1])), UUID(uuidString: String(parts[2])) != nil else { return nil }
        return (parent, Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
