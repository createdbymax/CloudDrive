import Foundation
import CryptoKit

/// Explicit local qualification transport, never selected for an R2 connection.
/// One actor serializes conditional mutations; no cloud credentials are involved.
public actor FixtureStorageRemote: StorageRemote {
    private let directory: URL
    private struct Value: Codable { var object: StorageObject; var data: Data }
    public init(directory: URL) throws {
        self.directory = directory; try CoreFileIO.privateDirectory(directory)
    }
    private func file(_ key: String) throws -> URL {
        guard !key.isEmpty, !key.contains("\0"), key.utf8.count <= 1024 else { throw StorageFailure.invalidResponse }
        return directory.appendingPathComponent(CoreFileIO.hash(Data(key.utf8)) + ".json")
    }
    private func load(_ key: String) throws -> Value? {
        let url = try file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Value.self, from: CoreFileIO.read(url, maximum: 32_000_000))
        guard value.object.key == key, value.object.size == value.data.count,
              value.object.validator == "\"" + CoreFileIO.hash(value.data) + "\"" else { throw StorageFailure.integrity }
        return value
    }
    public func head(key: String) throws -> StorageObject? { try load(key)?.object }
    public func read(key: String, range: Range<Int64>, validator: String) throws -> StorageRange {
        guard let value = try load(key) else { throw StorageFailure.notFound }
        guard value.object.validator == validator else { throw StorageFailure.conflict }
        guard range.lowerBound >= 0, range.upperBound <= value.object.size, range.count <= 16_777_216 else { throw StorageFailure.invalidRange }
        return StorageRange(data: value.data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), offset: range.lowerBound,
                            totalSize: value.object.size, validator: validator)
    }
    public func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) throws -> StorageObject {
        guard data.count <= 16_777_216 else { throw StorageFailure.unsupported }
        let previous = try load(key)
        switch condition {
        case .absent: guard previous == nil else { throw StorageFailure.conflict }
        case .matches(let tag): guard previous?.object.validator == tag else { throw StorageFailure.conflict }
        case .unconditional: break
        }
        let hash = CoreFileIO.hash(data)
        let object = StorageObject(key: key, size: Int64(data.count), validator: "\"" + hash + "\"", checksum: hash, operationID: operationID)
        try CoreFileIO.atomic(JSONEncoder().encode(Value(object: object, data: data)), at: file(key)); return object
    }
    public func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) throws -> StorageObject {
        guard let original = try load(source) else { throw StorageFailure.notFound }
        guard original.object.validator == sourceValidator else { throw StorageFailure.conflict }
        if let existing = try load(destination), existing.object.operationID == operationID, existing.data == original.data { return existing.object }
        return try put(key: destination, data: original.data, condition: .absent, operationID: operationID)
    }
    public func delete(key: String, validator: String) throws {
        guard let value = try load(key) else { return }
        guard value.object.validator == validator else { throw StorageFailure.conflict }
        try CoreFileIO.remove(file(key))
    }
    public func setModifiedAt(key: String, validator: String, date: Date, operationID: UUID) throws -> StorageObject {
        guard var value = try load(key) else { throw StorageFailure.notFound }
        if value.object.operationID == operationID, value.object.modifiedAt == date { return value.object }
        guard value.object.validator == validator else { throw StorageFailure.conflict }
        value.object.modifiedAt = date; value.object.operationID = operationID
        try CoreFileIO.atomic(JSONEncoder().encode(value), at: file(key)); return value.object
    }
    public func list(prefix: String, cursor: String?, limit: Int) throws -> StoragePage {
        guard (1...1000).contains(limit) else { throw StorageFailure.invalidResponse }
        var objects: [StorageObject] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let value = try JSONDecoder().decode(Value.self, from: CoreFileIO.read(file, maximum: 32_000_000))
            if value.object.key.hasPrefix(prefix), cursor == nil || value.object.key > cursor! { objects.append(value.object) }
        }
        objects.sort { $0.key < $1.key }; let page = Array(objects.prefix(limit))
        return StoragePage(objects: page, nextCursor: objects.count > limit ? page.last?.key : nil)
    }
}
