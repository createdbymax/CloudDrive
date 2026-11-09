import Foundation
import CryptoKit
import Darwin

/// Managed-only encryption boundary. Provider validators retain their CAS meaning;
/// provider ciphertext hashes are never presented as plaintext checksums.
public actor EncryptedStorageRemote: StorageRemote {
    private let base: any StorageRemote
    private let master: Data
    private let keyID: String
    private let root: String
    private let contentRoot: String
    private let aliasRoot: String
    private let journal: URL
    private let identity: CoreDirectoryIdentity
    private let lockFD: Int32
    private struct Intent: Codable { let version: Int; let key: String; let keyID: String; let size: Int64; let salt: Data }
    public init(base: any StorageRemote, masterKey: Data, keyID: String, prefix: String, journalDirectory: URL) throws {
        guard masterKey.count == 32, EncryptedDriveKey.identifier(for: masterKey) == keyID else { throw StorageFailure.integrity }
        self.base = base; master = masterKey; self.keyID = keyID
        root = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/.clouddrive/v1/"
        contentRoot = root + "content/"; aliasRoot = contentRoot + ".encrypted/"
        journal = journalDirectory; try CoreFileIO.privateDirectory(journal); identity = try CoreDirectoryIdentity(journal)
        lockFD = try CoreFileIO.lock(journal.appendingPathComponent("owner.lock"))
    }
    deinit { Darwin.close(lockFD) }
    private func context(_ key: String) -> Data { Data(SHA256.hash(data: Data(key.utf8))) }
    private func target(_ key: String) throws -> (physical: String, context: Data) {
        guard key.hasPrefix(root), key.utf8.count <= 1024 else { throw StorageFailure.unsupported }
        if key.hasPrefix(aliasRoot) {
            let pieces = key.dropFirst(aliasRoot.count).split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2, let digest = decode(String(pieces[0])), digest.count == 32,
                  let suffix = decode(String(pieces[1])), let relative = String(data: suffix, encoding: .utf8),
                  !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains(".."), !relative.contains("\0") else { throw StorageFailure.integrity }
            return (contentRoot + relative, digest)
        }
        return (key, context(key))
    }
    private func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func decode(_ string: String) -> Data? {
        let value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    private func logical(_ object: StorageObject, key: String, size: Int64) -> StorageObject {
        StorageObject(key: key, size: size, validator: object.validator, operationID: object.operationID, modifiedAt: object.modifiedAt)
    }
    private func header(key: String, object: StorageObject) async throws -> EncryptedObjectHeader {
        let resolved = try target(key)
        guard object.key == resolved.physical, object.size >= EncryptedObjectHeader.byteCount else { throw StorageFailure.integrity }
        let bytes = try await base.read(key: resolved.physical, range: 0..<Int64(EncryptedObjectHeader.byteCount), validator: object.validator)
        guard bytes.offset == 0, bytes.totalSize == object.size, bytes.validator == object.validator, bytes.data.count == EncryptedObjectHeader.byteCount else { throw StorageFailure.integrity }
        let header = try EncryptedObjectHeader.parse(bytes.data, context: resolved.context, master: master)
        guard header.encodedSize == object.size else { throw StorageFailure.integrity }
        return header
    }
    public func head(key: String) async throws -> StorageObject? {
        let resolved = try target(key)
        guard let object = try await base.head(key: resolved.physical) else { return nil }
        return try await logical(object, key: key, size: header(key: key, object: object).size)
    }
    public func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange {
        guard range.lowerBound >= 0, range.count <= 8 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        let resolved = try target(key)
        guard let object = try await base.head(key: resolved.physical) else { throw StorageFailure.notFound }
        guard object.validator == validator else { throw StorageFailure.conflict }
        let header = try await header(key: key, object: object)
        guard range.upperBound <= header.size else { throw StorageFailure.invalidRange }
        var result = Data(); result.reserveCapacity(range.count)
        if !range.isEmpty {
            let first = range.lowerBound / Int64(EncryptedObjectHeader.chunkSize), last = (range.upperBound - 1) / Int64(EncryptedObjectHeader.chunkSize)
            for index in first...last {
                let encodedRange = header.ciphertextRange(index)
                let bytes = try await base.read(key: resolved.physical, range: encodedRange, validator: validator)
                guard bytes.offset == encodedRange.lowerBound, bytes.totalSize == object.size, bytes.validator == validator else { throw StorageFailure.integrity }
                let plaintext = try header.open(bytes.data, index: index, master: master), source = header.plaintextRange(index)
                result.append(plaintext.subdata(in: Int(max(range.lowerBound, source.lowerBound) - source.lowerBound)..<Int(min(range.upperBound, source.upperBound) - source.lowerBound)))
            }
        }
        return StorageRange(data: result, offset: range.lowerBound, totalSize: header.size, validator: validator)
    }
    public func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject {
        guard data.count <= 8 * 1024 * 1024 else { throw StorageFailure.unsupported }
        return try await upload(key: key, size: Int64(data.count), condition: condition, operationID: operationID) { range in data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
    }
    public func upload(key: String, size: Int64, condition: StorageCondition, operationID: UUID,
                       reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        try await send(key: key, size: size, condition: condition, operationID: operationID, immutable: false, reader: reader)
    }
    public func uploadContent(keyHint: String, size: Int64, operationID: UUID,
                              reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        guard keyHint.hasPrefix(contentRoot) else { throw StorageFailure.unsupported }
        return try await send(key: keyHint, size: size, condition: .absent, operationID: operationID, immutable: true, reader: reader)
    }
    private func send(key: String, size: Int64, condition: StorageCondition, operationID: UUID, immutable: Bool,
                      reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        try identity.validate()
        let resolved = try target(key); guard resolved.physical == key, !key.hasPrefix(aliasRoot) else { throw StorageFailure.unsupported }
        let directory = journal.appendingPathComponent(CoreFileIO.hash(Data((key + operationID.uuidString).utf8)))
        let existingIntentDirectory = FileManager.default.fileExists(atPath: directory.path)
        try CoreFileIO.privateDirectory(directory)
        let intentURL = directory.appendingPathComponent("intent.json")
        let intent: Intent
        if FileManager.default.fileExists(atPath: intentURL.path) {
            intent = try CoreFileIO.readChecked(Intent.self, at: intentURL, maximum: 8192)
            guard intent.version == 1, intent.key == key, intent.keyID == keyID, intent.size == size else { throw StorageFailure.integrity }
        } else {
            // A missing intent in an existing upload journal is corruption, not
            // permission to pick a fresh salt and mix old/new multipart chunks.
            guard !existingIntentDirectory else { throw StorageFailure.integrity }
            intent = Intent(version: 1, key: key, keyID: keyID, size: size, salt: EncryptedDriveKey.generate())
            try CoreFileIO.atomicChecked(intent, at: intentURL)
        }
        let header = try EncryptedObjectHeader.create(size: size, salt: intent.salt, context: resolved.context, master: master)
        let encryptedReader: @Sendable (Range<Int64>) async throws -> Data = { [self] range in
            try await encodedRange(range, header: header, directory: directory, reader: reader)
        }
        let object: StorageObject
        if immutable { object = try await base.uploadContent(keyHint: key, size: header.encodedSize, operationID: operationID, reader: encryptedReader) }
        else { object = try await base.upload(key: key, size: header.encodedSize, condition: condition, operationID: operationID, reader: encryptedReader) }
        guard object.size == header.encodedSize, !object.validator.isEmpty else { throw StorageFailure.integrity }
        var locator = key
        if object.key != key {
            guard immutable, object.key.hasPrefix(contentRoot), !object.key.hasPrefix(aliasRoot) else { throw StorageFailure.integrity }
            locator = aliasRoot + encode(resolved.context) + "/" + encode(Data(object.key.dropFirst(contentRoot.count).utf8))
            guard locator.utf8.count <= 1024 else { throw StorageFailure.integrity }
        }
        _ = try await self.header(key: locator, object: object)
        return logical(object, key: locator, size: size)
    }
    private func encodedRange(_ range: Range<Int64>, header: EncryptedObjectHeader, directory: URL,
                               reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> Data {
        try identity.validate()
        guard range.lowerBound >= 0, range.upperBound <= header.encodedSize, range.count <= 64 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        if range.isEmpty { return Data() }
        var result = Data(); result.reserveCapacity(range.count)
        if range.lowerBound < EncryptedObjectHeader.byteCount {
            result.append(header.bytes.subdata(in: Int(range.lowerBound)..<Int(min(range.upperBound, Int64(EncryptedObjectHeader.byteCount)))))
        }
        if range.upperBound > EncryptedObjectHeader.byteCount {
            let start = max(range.lowerBound, Int64(EncryptedObjectHeader.byteCount)) - Int64(EncryptedObjectHeader.byteCount)
            let first = start / Int64(EncryptedObjectHeader.chunkSize + 16)
            let last = (range.upperBound - Int64(EncryptedObjectHeader.byteCount) - 1) / Int64(EncryptedObjectHeader.chunkSize + 16)
            for index in first...last {
                let plaintextRange = header.plaintextRange(index), bytes = try await reader(header.plaintextRange(index))
                guard bytes.count == plaintextRange.count else { throw StorageFailure.integrity }
                // Persist digest BEFORE using this nonce. A changed replay is rejected
                // before encryption, including after an interrupted multipart upload.
                let digestURL = directory.appendingPathComponent(String(index) + ".json"), digest = CoreFileIO.hash(bytes)
                if FileManager.default.fileExists(atPath: digestURL.path) {
                    guard try CoreFileIO.readChecked(String.self, at: digestURL, maximum: 128) == digest else { throw StorageFailure.integrity }
                } else { try CoreFileIO.atomicChecked(digest, at: digestURL) }
                let encoded = try header.seal(bytes, index: index, master: master), source = header.ciphertextRange(index)
                result.append(encoded.subdata(in: Int(max(range.lowerBound, source.lowerBound) - source.lowerBound)..<Int(min(range.upperBound, source.upperBound) - source.lowerBound)))
            }
        }
        return result
    }
    public func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) async throws -> StorageObject { throw StorageFailure.unsupported }
    public func setModifiedAt(key: String, validator: String, date: Date, operationID: UUID) async throws -> StorageObject { throw StorageFailure.unsupported }
    public func removeWritebackObject(_ object: StorageObject, id: UUID, checksum: String) async throws {
        guard object.key == root + "writeback/" + id.uuidString + "/" + checksum, object.operationID == id else { throw StorageFailure.integrity }
        guard let physical = try await base.head(key: object.key) else { return }
        guard physical.validator == object.validator, physical.operationID == id else { throw StorageFailure.conflict }
        try await base.removeWritebackObject(physical, id: id, checksum: checksum)
    }
    public func delete(key: String, validator: String) async throws {
        guard let object = try await head(key: key), object.validator == validator else { throw StorageFailure.conflict }
        try await base.delete(key: target(key).physical, validator: validator)
    }
    public func list(prefix: String, cursor: String?, limit: Int) async throws -> StoragePage {
        // New encrypted volumes admit an empty prefix only. Plaintext migration and
        // server-side ordinary-key export are deliberately unavailable.
        let page = try await base.list(prefix: prefix, cursor: cursor, limit: limit)
        guard page.objects.isEmpty, page.nextCursor == nil else { throw StorageFailure.unsupported }
        return page
    }
}
