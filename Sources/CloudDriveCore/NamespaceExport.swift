import Foundation

public enum NamespaceExportFailure: Error {
    case finderMetadata
    public static let finderMetadataMessage = "This drive contains Finder metadata that an ordinary R2 folder cannot preserve. Copy the items in Finder to a Mac-formatted volume to keep that metadata."
}

public struct NamespaceExportProgress: Codable, Sendable {
    public var exportID: UUID
    public var destinationPrefix: String
    public var revision: Int64
    public var files: Int64
    public var bytes: Int64
    public var complete: Bool
}

/// Materialize a published managed snapshot into an unused ordinary-key prefix.
/// Export never deletes source objects, changes storage mode or downgrades a drive.
public actor NamespaceExporter {
    private let store: NamespaceStore
    private let content: ContentStore
    private let remote: any StorageRemote
    private let directory: URL
    private let storagePrefix: String
    private var running = false
    private struct Frame: Codable { var nodeID: UUID; var path: String; var cursor: String? }
    private struct State: Codable {
        var volumeID: UUID
        var progress: NamespaceExportProgress
        var stack: [Frame]
        var current: Item?
        var metadataChecked: Bool? = nil
    }
    private struct Item: Codable {
        var node: NamespaceNode
        var path: String
        var operationID: UUID
        var source: ObjectLocator?
    }
    public init(store: NamespaceStore, content: ContentStore, remote: any StorageRemote, prefix: String, directory: URL) {
        self.store = store; self.content = content; self.remote = remote
        self.storagePrefix = prefix; self.directory = directory
    }
    public func export(to destination: String) async throws -> NamespaceExportProgress {
        guard !running else { throw StorageFailure.busy }; running = true; defer { running = false }
        guard destination.hasPrefix(storagePrefix + "/"), destination != storagePrefix,
              !destination.hasPrefix(storagePrefix + "/.clouddrive/"), !destination.hasSuffix("/"), destination.utf8.count < 900,
              !destination.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw StorageFailure.invalidResponse }
        let volume = try await store.volume()
        guard volume.mode == .managed, volume.publishedRevision == volume.revision,
              try await store.operations(limit: 1).isEmpty else { throw StorageFailure.busy }
        try CoreFileIO.privateDirectory(directory)
        let checkpoint = directory.appendingPathComponent(CoreFileIO.hash(Data(destination.utf8)) + ".json")
        var state: State
        if FileManager.default.fileExists(atPath: checkpoint.path) {
            state = try CoreFileIO.readChecked(State.self, at: checkpoint, maximum: 16_777_216)
            guard state.volumeID == volume.id, state.progress.destinationPrefix == destination,
                  state.progress.revision <= volume.revision, state.stack.count <= 4096 else { throw StorageFailure.integrity }
        } else {
            guard try await remote.head(key: destination) == nil,
                  try await remote.list(prefix: destination + "/", cursor: nil, limit: 1).objects.isEmpty else { throw StorageFailure.conflict }
            state = State(volumeID: volume.id,
                progress: NamespaceExportProgress(exportID: UUID(), destinationPrefix: destination, revision: volume.revision, files: 0, bytes: 0, complete: false),
                stack: [.init(nodeID: volume.rootID, path: "", cursor: nil)])
        }
        if state.progress.complete { return state.progress }
        if state.metadataChecked != true {
            guard try await !store.hasNativeMetadataForExport(root: volume.rootID, revision: state.progress.revision) else {
                throw NamespaceExportFailure.finderMetadata
            }
            state.metadataChecked = true
            try CoreFileIO.atomicChecked(state, at: checkpoint)
        }
        while !state.stack.isEmpty {
            try Task.checkCancellation()
            if state.current == nil {
                let frame = state.stack[state.stack.count - 1]
                let page = try await store.listAsOf(parentID: frame.nodeID, revision: state.progress.revision, after: frame.cursor, limit: 1)
                guard let node = page.nodes.first else { state.stack.removeLast(); try CoreFileIO.atomicChecked(state, at: checkpoint); continue }
                let path = frame.path.isEmpty ? node.name : frame.path + "/" + node.name
                let locator = try await store.publishedLocator(nodeID: node.id, generation: node.contentGeneration) ?? node.backing
                state.current = Item(node: node, path: path, operationID: UUID(), source: locator)
                try CoreFileIO.atomicChecked(state, at: checkpoint)
            }
            guard let item = state.current else { throw StorageFailure.integrity }
            let key = destination + "/" + item.path + (item.node.kind == .directory ? "/" : "")
            if item.node.kind == .directory || item.node.size == 0 && item.source == nil {
                if let existing = try await remote.head(key: key) {
                    guard existing.operationID == item.operationID, existing.size == 0 else { throw StorageFailure.conflict }
                } else { _ = try await remote.put(key: key, data: Data(), condition: .absent, operationID: item.operationID) }
            } else {
                guard let original = item.source else { throw StorageFailure.integrity }
                let locator = try await content.resolve(original)
                guard let tag = locator.validator, locator.size == item.node.size else { throw StorageFailure.integrity }
                let copied = try await remote.copy(source: locator.key, destination: key, sourceValidator: tag, operationID: item.operationID)
                guard copied.key == key, copied.size == locator.size,
                      locator.checksum == nil || copied.checksum == locator.checksum else { throw StorageFailure.integrity }
                guard let verified = try await remote.head(key: key), verified.validator == copied.validator,
                      verified.size == copied.size, verified.operationID == item.operationID else { throw StorageFailure.integrity }
            }
            guard state.progress.files < Int64.max, state.progress.bytes <= Int64.max - item.node.size else { throw StorageFailure.integrity }
            state.stack[state.stack.count - 1].cursor = item.node.id.uuidString
            if item.node.kind == .directory {
                guard state.stack.count < 4096 else { throw StorageFailure.integrity }
                state.stack.append(.init(nodeID: item.node.id, path: item.path))
            } else { state.progress.files += 1; state.progress.bytes += item.node.size }
            state.current = nil; try CoreFileIO.atomicChecked(state, at: checkpoint)
        }
        state.progress.complete = true; try CoreFileIO.atomicChecked(state, at: checkpoint)
        return state.progress
    }
}
