import Foundation

public enum NamespaceRecovery {
    private struct Checkpoint: Codable {
        var binding: String
        var head: ManagedHead
        var headValidator: String
        var rootID: UUID
        var revision: Int64
        var complete: Bool
    }
    /// Explicit remote recovery only. An existing nonempty or incompatible local
    /// store is never replaced with a new tree or reinterpreted as an empty drive.
    public static func restoreManaged(remote: any StorageRemote, prefix: String, directory: URL, binding: String) async throws -> NamespaceStore {
        try CoreFileIO.privateDirectory(directory)
        let key = prefix + "/.clouddrive/v1/HEAD"
        guard let object = try await remote.head(key: key), object.size > 0, object.size <= 4096 else { throw StorageFailure.notFound }
        let bytes = try await remote.read(key: key, range: 0..<object.size, validator: object.validator)
        guard bytes.data.count == object.size, bytes.validator == object.validator, bytes.totalSize == object.size else { throw StorageFailure.integrity }
        let head = try JSONDecoder().decode(ManagedHead.self, from: bytes.data)
        guard (1...2).contains(head.version), head.commitID.count == 64, head.commitID.allSatisfy({ $0.isHexDigit }) else { throw StorageFailure.integrity }
        let publisher = ManagedManifestPublisher(remote: remote, prefix: prefix, volumeID: head.volumeID, expectedHead: object)
        guard let commit = try await publisher.load() else { throw StorageFailure.notFound }
        let records = try await publisher.exportRecords()
        let roots = records.filter { $0.parentID == nil }
        guard roots.count == 1, roots[0].kind == .directory, roots[0].name.isEmpty else { throw StorageFailure.integrity }
        let checkpointURL = directory.appendingPathComponent("managed-recovery.json")
        var checkpoint = Checkpoint(binding: binding, head: head, headValidator: object.validator, rootID: roots[0].id, revision: commit.revision, complete: false)
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            let prior = try CoreFileIO.readChecked(Checkpoint.self, at: checkpointURL, maximum: 65_536)
            guard prior.binding == binding, prior.head == head, prior.headValidator == object.validator,
                  prior.rootID == checkpoint.rootID, prior.revision == checkpoint.revision else { throw StorageFailure.conflict }
            checkpoint = prior
        }
        let store = try NamespaceStore(directory: directory.appendingPathComponent("Namespace"), binding: binding, mode: .managed,
                                       volumeID: head.volumeID, rootID: checkpoint.rootID)
        do {
            if !checkpoint.complete {
                try CoreFileIO.atomicChecked(checkpoint, at: checkpointURL)
                let current = try await store.volume()
                if current.revision == 0 {
                    try await store.restoreManaged(records: records, volumeID: head.volumeID, revision: commit.revision)
                } else {
                    // The restore transaction may have committed immediately before
                    // process death, while its external checkpoint still says pending.
                    guard current.revision == commit.revision, current.publishedRevision == commit.revision,
                          try await store.operations(limit: 1).isEmpty else { throw StorageFailure.conflict }
                    try await verifyRestored(store, records: records)
                }
                try await store.recordNamespacePublication(revision: commit.revision, validator: head.commitID)
                checkpoint.complete = true; try CoreFileIO.atomicChecked(checkpoint, at: checkpointURL)
            } else {
                let volume = try await store.volume()
                guard volume.id == head.volumeID, volume.rootID == checkpoint.rootID, volume.revision == checkpoint.revision,
                      volume.publishedRevision == volume.revision, try await store.operations(limit: 1).isEmpty else { throw StorageFailure.conflict }
            }
            var bytes: Int64 = 0
            for record in records where record.kind == .file {
                guard record.size >= 0, bytes <= Int64.max - record.size else { throw StorageFailure.integrity }
                bytes += record.size
            }
            let progress = NamespaceImportProgress(binding: binding, volumeID: head.volumeID, prefix: prefix, objects: Int64(max(0, records.count - 1)), bytes: bytes, complete: true)
            try CoreFileIO.atomicChecked(progress, at: directory.appendingPathComponent("namespace-import.json"))
            return store
        } catch { await store.close(); throw error }
    }
    private static func verifyRestored(_ store: NamespaceStore, records: [ManagedNodeRecord]) async throws {
        for expected in records {
            let actual = try await store.node(expected.id)
            guard actual.parentID == expected.parentID, actual.name == expected.name, actual.kind == expected.kind,
                  expected.inode == nil || actual.inode == expected.inode,
                  actual.xattrs == expected.xattrs, actual.size == expected.size, actual.contentGeneration == expected.generation,
                  actual.metadataGeneration == (expected.metadataGeneration ?? 0), actual.backing == expected.backing,
                  abs(actual.modifiedAt.timeIntervalSince(expected.modifiedAt)) < 0.000_001 else { throw StorageFailure.conflict }
        }
        var cursor: String?, count = 0
        while true {
            let page = try await store.allNodes(after: cursor, limit: 256); count += page.nodes.count
            guard let next = page.next else { break }; cursor = next
        }
        guard count == records.count else { throw StorageFailure.conflict }
    }
}
