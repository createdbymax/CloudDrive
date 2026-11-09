import Foundation

public struct NamespaceImportProgress: Codable, Equatable, Sendable {
    public var binding: String
    public var volumeID: UUID
    public var prefix: String
    public var cursor: String?
    public var objects: Int64
    public var bytes: Int64
    public var complete: Bool
}

/// A read-only import copies metadata, not file payloads. Completed page transactions
/// precede cursor persistence; replaying a page must validate the same imported nodes.
public actor NamespaceMigration {
    private let store: NamespaceStore
    private let remote: any StorageRemote
    private let prefix: String
    private let checkpoint: URL
    private var running = false
    private struct CompatibleFormat: Codable { var version = 1; var binding: String; var mode: NamespaceStorageMode = .compatible; var volumeID: UUID }
    public init(store: NamespaceStore, remote: any StorageRemote, prefix: String, directory: URL) {
        self.store = store; self.remote = remote; self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        checkpoint = directory.appendingPathComponent("namespace-import.json")
    }
    public func progress() async throws -> NamespaceImportProgress {
        let volume = try await store.volume()
        if FileManager.default.fileExists(atPath: checkpoint.path) {
            let saved = try CoreFileIO.readChecked(NamespaceImportProgress.self, at: checkpoint, maximum: 65_536)
            guard saved.binding == volume.binding, saved.volumeID == volume.id, saved.prefix == prefix else { throw NamespaceFailure.bindingMismatch }
            return saved
        }
        return .init(binding: volume.binding, volumeID: volume.id, prefix: prefix, objects: 0, bytes: 0, complete: false)
    }
    public func importCompatible() async throws -> NamespaceImportProgress {
        guard !running else { throw StorageFailure.busy }
        running = true; defer { running = false }
        let volume = try await store.volume()
        guard try await store.operations(limit: 1).isEmpty else { throw NamespaceFailure.invalidTransition }
        var current = try await progress()
        guard !current.complete else { return current }
        var recognizedReserved: Bool?
        var seenCursors: Set<String> = []
        while true {
            try Task.checkCancellation()
            let page = try await remote.list(prefix: prefix + "/", cursor: current.cursor, limit: 1000)
            var entries: [NamespaceImportEntry] = []
            for object in page.objects {
                guard object.key.hasPrefix(prefix + "/") else { throw StorageFailure.integrity }
                let relative = String(object.key.dropFirst((prefix + "/").count))
                if relative.isEmpty { continue }
                // Reserved metadata never becomes an ordinary file or gets overwritten.
                if relative == ".clouddrive" || relative.hasPrefix(".clouddrive/") {
                    if recognizedReserved == nil { recognizedReserved = try await recognizesCompatibleMetadata() }
                    guard recognizedReserved == true else { throw NamespaceFailure.collision }
                    continue
                }
                let directory = relative.hasSuffix("/")
                if directory && object.size != 0 { throw NamespaceFailure.invalidName }
                let path = directory ? String(relative.dropLast()) : relative
                entries.append(NamespaceImportEntry(path: path, kind: directory ? .directory : .file, size: object.size,
                    modifiedAt: object.modifiedAt ?? Date(timeIntervalSince1970: 0),
                    backing: directory ? nil : ObjectLocator(key: object.key, validator: object.validator, size: object.size, checksum: object.checksum)))
                guard current.objects < Int64.max, current.bytes <= Int64.max - object.size else { throw NamespaceFailure.limitExceeded }
                current.objects += 1; current.bytes += object.size
            }
            try await store.importEntries(entries)
            if let next = page.nextCursor {
                guard next != current.cursor, seenCursors.insert(next).inserted else { throw StorageFailure.invalidResponse }
                current.cursor = next
            } else { current.complete = true; current.cursor = nil }
            try CoreFileIO.atomicChecked(current, at: checkpoint)
            if current.complete { return current }
        }
    }
    public func qualifyCompatibility() async throws {
        if let native = remote as? S3StorageRemote { try await native.qualifyConditionalDelete() }
        else if let limited = remote as? BandwidthLimitedStorageRemote { try await limited.qualifyConditionalDelete() }
        else { guard remote is FixtureStorageRemote else { throw StorageFailure.unsupported } }
        let volume = try await store.volume()
        guard volume.mode == .compatible else { throw NamespaceFailure.invalidTransition }
        let key = prefix + "/.clouddrive/v1/FORMAT"
        if try await remote.head(key: key) != nil {
            guard try await recognizesCompatibleMetadata() else { throw NamespaceFailure.collision }
        } else {
            let marker = CompatibleFormat(binding: volume.binding, volumeID: volume.id)
            _ = try await remote.put(key: key, data: JSONEncoder().encode(marker), condition: .absent, operationID: UUID())
        }
    }
    private func recognizesCompatibleMetadata() async throws -> Bool {
        let key = prefix + "/.clouddrive/v1/FORMAT"
        guard let object = try await remote.head(key: key), object.size > 0, object.size <= 16_384 else { return false }
        let bytes = try await remote.read(key: key, range: 0..<object.size, validator: object.validator)
        guard bytes.totalSize == object.size, bytes.data.count == object.size, bytes.validator == object.validator else { throw StorageFailure.integrity }
        let marker = try JSONDecoder().decode(CompatibleFormat.self, from: bytes.data)
        let volume = try await store.volume()
        return marker.version == 1 && marker.binding == volume.binding && marker.mode == .compatible
    }
}
