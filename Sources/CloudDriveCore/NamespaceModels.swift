import Foundation

public typealias NodeID = UUID
public typealias VolumeID = UUID

public enum NamespaceNodeKind: String, Codable, Sendable { case file, directory }
public enum NamespaceStorageMode: String, Codable, Sendable { case compatible, managed }
public enum NamespaceFailure: Error, Equatable, Sendable {
    case storage, ownership, incompatibleSchema, bindingMismatch, corrupt, notFound
    case invalidName, collision, notDirectory, isDirectory, directoryNotEmpty, cycle, rootProtected
    case generationChanged, operationNotFound, invalidTransition, limitExceeded
}

/// An opaque validator identifies a provider version; it is not assumed to be a checksum.
public struct ObjectLocator: Codable, Hashable, Sendable {
    public var key: String
    public var validator: String?
    public var size: Int64
    public var checksum: String?
    public init(key: String, validator: String? = nil, size: Int64, checksum: String? = nil) {
        self.key = key; self.validator = validator; self.size = size; self.checksum = checksum
    }
}

public struct NamespaceVolume: Codable, Equatable, Sendable {
    public let id: VolumeID
    public let rootID: NodeID
    public let binding: String
    public let mode: NamespaceStorageMode
    public let revision: Int64
    public let publishedRevision: Int64
    public var canCreateNativeXattrs: Bool? = nil
}

/// FSKit delegates names outside this explicit list to the system's metadata fallback.
public enum ManagedXattrs {
    public static let names = [
        "com.apple.FinderInfo", "com.apple.provenance", "com.apple.metadata:_kMDItemUserTags",
        "com.apple.metadata:kMDItemFinderComment", "com.apple.metadata:kMDItemResumableCopy",
        "com.apple.finder.copy.checkpoint", "com.apple.finder.copy.source"
    ]
    public static let maximumValueBytes = 4096
    static func validate(_ values: [String: Data]) throws {
        guard values.count <= names.count else { throw POSIXError(.E2BIG) }
        var total = 0
        for (name, value) in values {
            guard names.contains(name) else { throw POSIXError(.ENOTSUP) }
            guard name != "com.apple.FinderInfo" || value.count == 32 else { throw POSIXError(.EINVAL) }
            guard value.count <= maximumValueBytes else { throw POSIXError(.E2BIG) }
            total += value.count
        }
        guard total <= 6144 else { throw POSIXError(.E2BIG) }
    }
}

public struct NamespaceNode: Codable, Equatable, Sendable, Identifiable {
    public let id: NodeID
    public let inode: Int64
    public let parentID: NodeID?
    public let name: String
    public let kind: NamespaceNodeKind
    public let size: Int64
    public let contentGeneration: Int64
    public let metadataGeneration: Int64
    public let modifiedAt: Date
    public let deletedRevision: Int64?
    public let backing: ObjectLocator?
    public let stagedSnapshotID: UUID?
    public private(set) var xattrs: [String: Data]?
    func listingEntry() -> Self {
        var result = self
        if xattrs != nil { result.xattrs = [:] }
        return result
    }
    public init(id: NodeID, inode: Int64, parentID: NodeID?, name: String, kind: NamespaceNodeKind,
                size: Int64 = 0, contentGeneration: Int64 = 0, metadataGeneration: Int64 = 0,
                modifiedAt: Date = Date(), deletedRevision: Int64? = nil, backing: ObjectLocator? = nil,
                stagedSnapshotID: UUID? = nil, xattrs: [String: Data]? = nil) {
        self.id = id; self.inode = inode; self.parentID = parentID; self.name = name; self.kind = kind; self.size = size
        self.contentGeneration = contentGeneration; self.metadataGeneration = metadataGeneration; self.modifiedAt = modifiedAt
        self.deletedRevision = deletedRevision; self.backing = backing; self.stagedSnapshotID = stagedSnapshotID; self.xattrs = xattrs
    }
}

public struct NamespaceImportEntry: Sendable {
    public let path: String
    public let kind: NamespaceNodeKind
    public let size: Int64
    public let modifiedAt: Date
    public let backing: ObjectLocator?
    public init(path: String, kind: NamespaceNodeKind = .file, size: Int64 = 0, modifiedAt: Date = Date(), backing: ObjectLocator? = nil) {
        self.path = path; self.kind = kind; self.size = size; self.modifiedAt = modifiedAt; self.backing = backing
    }
}

public struct NamespacePage: Sendable {
    public let nodes: [NamespaceNode]
    /// Stable node-ID continuation, independent of names changed between page requests.
    public let next: String?
    public let revision: Int64
    var dotInodes: (directory: Int64, parent: Int64)? = nil
}

public enum NamespaceOperationKind: String, Codable, Sendable { case create, rename, remove, write, pin, metadata }
public enum NamespaceOperationState: String, Codable, Sendable { case pending, running, attention, complete }
public struct NamespaceOperation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: Int64
    public let requestDigest: String
    public let kind: NamespaceOperationKind
    public let nodeID: NodeID
    public let baseGeneration: Int64
    public let targetGeneration: Int64
    public let sourcePath: String?
    public let destinationPath: String?
    public let sourceLocator: ObjectLocator?
    public let replacedNodeID: NodeID?
    public let stagedSnapshotID: UUID?
    public let contentChecksum: String?
    public let modifiedAt: Date?
    public let nodeSnapshot: NamespaceNode?
    public let parentSnapshots: [NamespaceNode]?
    public let localOnly: Bool?
    public let dependencies: [UUID]
    public let state: NamespaceOperationState
    public let attemptCount: Int
    public let errorCode: String?
}

public struct NamespaceReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let stepID: String
    public let validator: String?
    public let recordedAt: Date
}

public struct NamespaceEvent: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let nodeID: NodeID
    public let revision: Int64
    public let kind: NamespaceOperationKind
}

/// A generation-scoped staged snapshot is accepted only after the caller has durably saved its bytes.
public struct NamespaceContentCommit: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let size: Int64
    public let checksum: String
    public init(snapshotID: UUID, size: Int64, checksum: String) {
        self.snapshotID = snapshotID; self.size = size; self.checksum = checksum
    }
}

public struct NamespaceRestoreStatus: Codable, Equatable, Sendable {
    public let volumeID: UUID
    public let rootID: UUID
    public let revision: Int64
    public let stagedRecords: Int
}
