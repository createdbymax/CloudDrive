import Foundation

public struct StorageObject: Codable, Equatable, Sendable {
    public var key: String
    public var size: Int64
    public var validator: String
    public var checksum: String?
    public var operationID: UUID?
    public var modifiedAt: Date?
    public init(key: String, size: Int64, validator: String, checksum: String? = nil, operationID: UUID? = nil, modifiedAt: Date? = nil) {
        self.key = key; self.size = size; self.validator = validator; self.checksum = checksum; self.operationID = operationID; self.modifiedAt = modifiedAt
    }
}
public struct StorageRange: Sendable {
    public var data: Data
    public var offset: Int64
    public var totalSize: Int64
    public var validator: String
    public init(data: Data, offset: Int64, totalSize: Int64, validator: String) {
        self.data = data; self.offset = offset; self.totalSize = totalSize; self.validator = validator
    }
}
public struct StoragePage: Sendable {
    public var objects: [StorageObject]
    public var nextCursor: String?
    public init(objects: [StorageObject], nextCursor: String? = nil) { self.objects = objects; self.nextCursor = nextCursor }
}
public enum StorageCondition: Sendable, Equatable { case unconditional, absent, matches(String) }
public enum StorageFailure: Error, Equatable, Sendable {
    case notFound, conflict, unknownOutcome, invalidResponse, offline, unsupported, invalidRange, fileTooLarge, localStorageFull, integrity, busy
}

/// The transport must reject redirects, validate byte ranges, and preserve conditional
/// requests. A validator is an opaque precondition, never implicitly a checksum.
public protocol StorageRemote: Sendable {
    func head(key: String) async throws -> StorageObject?
    func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange
    func readContentAddressed(key: String, maximum: Int, checksum: String) async throws -> Data
    func putContentAddressed(key: String, data: Data, operationID: UUID) async throws
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) async throws -> StorageObject
    /// Conditional deletion is a required capability. A transport that cannot atomically
    /// honor the validator must throw unsupported, preserving the source.
    func delete(key: String, validator: String) async throws
    func removeWritebackObject(_ object: StorageObject, id: UUID, checksum: String) async throws
    func setModifiedAt(key: String, validator: String, date: Date, operationID: UUID) async throws -> StorageObject
    func list(prefix: String, cursor: String?, limit: Int) async throws -> StoragePage
    /// The reader is repeatable over an immutable generation; multipart transports can
    /// bound memory without making an additional full local payload copy.
    func uploadContent(keyHint: String, size: Int64, operationID: UUID, reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject
    func upload(key: String, size: Int64, condition: StorageCondition, operationID: UUID,
                reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject
}

public extension StorageRemote {
    func putContentAddressed(key: String, data: Data, operationID: UUID) async throws {
        guard key.hasSuffix("/" + CoreFileIO.hash(data)) else { throw StorageFailure.integrity }
        _ = try await put(key: key, data: data, condition: .absent, operationID: operationID)
    }
    /// The expected digest authenticates the entire immutable response.
    func readContentAddressed(key: String, maximum: Int, checksum: String) async throws -> Data {
        guard let object = try await head(key: key), object.size >= 0, object.size <= maximum else {
            throw StorageFailure.integrity
        }
        if object.size == 0 {
            guard CoreFileIO.hash(Data()) == checksum else { throw StorageFailure.integrity }
            return Data()
        }
        let response = try await read(key: key, range: 0..<object.size, validator: object.validator)
        guard response.offset == 0, response.totalSize == object.size, response.data.count == object.size,
              response.validator == object.validator else { throw StorageFailure.invalidResponse }
        guard CoreFileIO.hash(response.data) == checksum else { throw StorageFailure.integrity }
        return response.data
    }
    func removeWritebackObject(_ object: StorageObject, id: UUID, checksum: String) async throws {
        guard object.operationID == id, object.key.hasSuffix("/.clouddrive/v1/writeback/" + id.uuidString + "/" + checksum) else { throw StorageFailure.integrity }
        try await delete(key: object.key, validator: object.validator)
    }
    func uploadContent(keyHint: String, size: Int64, operationID: UUID,
                       reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        try await upload(key: keyHint, size: size, condition: .absent, operationID: operationID, reader: reader)
    }
    func setModifiedAt(key: String, validator: String, date: Date, operationID: UUID) async throws -> StorageObject { throw StorageFailure.unsupported }
    func upload(key: String, size: Int64, condition: StorageCondition, operationID: UUID,
                reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        guard size >= 0, size <= 8 * 1024 * 1024 else { throw StorageFailure.unsupported }
        let data = try await reader(0..<size)
        guard data.count == size else { throw StorageFailure.invalidResponse }
        return try await put(key: key, data: data, condition: condition, operationID: operationID)
    }
}
