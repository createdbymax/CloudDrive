import XCTest
import Foundation
@testable import CloudDriveCore

private actor EncryptedFixtureRemote: StorageRemote {
    struct Value { var object: StorageObject; var bytes: Data }
    var values: [String: Value] = [:]
    var sequence = 0
    var rejectUploads = false
    func failUploads(_ value: Bool) { rejectUploads = value }
    func allBytes() -> [Data] { values.values.map(\.bytes) }
    func objects() -> [StorageObject] { values.values.map(\.object) }
    func corrupt(_ key: String, at offset: Int) { values[key]!.bytes[offset] ^= 1 }
    func transplant(_ source: String, to destination: String) { values[destination]!.bytes = values[source]!.bytes }
    func head(key: String) -> StorageObject? { values[key]?.object }
    func read(key: String, range: Range<Int64>, validator: String) throws -> StorageRange {
        guard let value = values[key] else { throw StorageFailure.notFound }
        guard value.object.validator == validator else { throw StorageFailure.conflict }
        guard range.lowerBound >= 0, range.upperBound <= value.object.size else { throw StorageFailure.invalidRange }
        return StorageRange(data: value.bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), offset: range.lowerBound, totalSize: value.object.size, validator: validator)
    }
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) throws -> StorageObject {
        switch condition {
        case .absent: guard values[key] == nil else { throw StorageFailure.conflict }
        case .matches(let tag): guard values[key]?.object.validator == tag else { throw StorageFailure.conflict }
        case .unconditional: break
        }
        sequence += 1
        let value = StorageObject(key: key, size: Int64(data.count), validator: "e\(sequence)", checksum: CoreFileIO.hash(data), operationID: operationID)
        values[key] = Value(object: value, bytes: data); return value
    }
    func uploadContent(keyHint: String, size: Int64, operationID: UUID, reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        let prefix = String(keyHint.prefix(upTo: keyHint.range(of: "/content/")!.upperBound))
        let key = prefix + "physical-" + operationID.uuidString
        // Deliberately exercise arbitrary part boundaries and repeat reads.
        var encoded = Data(), offset: Int64 = 0
        while offset < size {
            let end = min(size, offset + 700_003), first = try await reader(offset..<end), repeated = try await reader(offset..<end)
            let empty = try await reader(end..<end)
            guard first == repeated, empty.isEmpty else { throw StorageFailure.integrity }
            encoded.append(first); offset = end
        }
        if rejectUploads { throw StorageFailure.offline }
        return try put(key: key, data: encoded, condition: .absent, operationID: operationID)
    }
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) throws -> StorageObject { throw StorageFailure.unsupported }
    func delete(key: String, validator: String) throws {
        guard values[key]?.object.validator == validator else { throw StorageFailure.conflict }; values.removeValue(forKey: key)
    }
    func list(prefix: String, cursor: String?, limit: Int) -> StoragePage {
        StoragePage(objects: Array(values.values.map(\.object).filter { $0.key.hasPrefix(prefix) }.prefix(limit)))
    }
}

final class EncryptedStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return value
    }
    private func wrapper(_ base: EncryptedFixtureRemote, _ key: Data, _ directory: URL) throws -> EncryptedStorageRemote {
        try EncryptedStorageRemote(base: base, masterKey: key, keyID: EncryptedDriveKey.identifier(for: key), prefix: "Drive", journalDirectory: directory)
    }
    func testRecoveryEnvelopeRoundTripAndTamperWrongKeyRejection() throws {
        let key = EncryptedDriveKey.generate(), id = EncryptedDriveKey.identifier(for: key)
        let recovery = try EncryptedDriveRecoveryEnvelope.create(masterKey: key, keyID: id)
        let saved = try JSONEncoder().encode(recovery.envelope)
        let envelope = try JSONDecoder().decode(EncryptedDriveRecoveryEnvelope.self, from: saved)
        XCTAssertEqual(try envelope.recover(recoveryKey: recovery.recoveryKey), key)
        XCTAssertThrowsError(try envelope.recover(recoveryKey: EncryptedDriveKey.generate().base64EncodedString()))
        XCTAssertThrowsError(try envelope.recover(recoveryKey: "password"))
        var json = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        json["keyID"] = String(repeating: "a", count: 64)
        let changed = try JSONDecoder().decode(EncryptedDriveRecoveryEnvelope.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try changed.recover(recoveryKey: recovery.recoveryKey))
    }
    func testEncryptedContentRandomPhysicalKeyRangesAndRepeatedParts() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let base = EncryptedFixtureRemote(), key = EncryptedDriveKey.generate(), remote = try wrapper(base, key, directory)
        let bytes = Data((0..<(2 * 1_048_576 + 123)).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let object = try await remote.uploadContent(keyHint: "Drive/.clouddrive/v1/content/node/3/op", size: Int64(bytes.count), operationID: UUID()) { range in bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
        XCTAssertTrue(object.key.contains("/.encrypted/")); XCTAssertEqual(object.size, Int64(bytes.count)); XCTAssertNil(object.checksum)
        for range: Range<Int64> in [0..<1, 1_048_570..<1_048_600, 2_097_150..<Int64(bytes.count), 10..<10] {
            let read = try await remote.read(key: object.key, range: range, validator: object.validator)
            XCTAssertEqual(read.data, bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
            XCTAssertEqual(read.totalSize, Int64(bytes.count)); XCTAssertEqual(read.offset, range.lowerBound)
        }
        let stored = await base.allBytes(); XCTAssertEqual(stored.count, 1); XCTAssertNotEqual(stored.first, bytes)
        let listed = try await remote.head(key: object.key); XCTAssertEqual(listed?.size, object.size)
    }
    func testMetadataCASWrongKeyTransplantAndCiphertextCorruptionFailClosed() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let base = EncryptedFixtureRemote(), key = EncryptedDriveKey.generate(), remote = try wrapper(base, key, directory.appendingPathComponent("right"))
        let a = "Drive/.clouddrive/v1/HEAD", b = "Drive/.clouddrive/v1/commits/other"
        let first = try await remote.put(key: a, data: Data("secret-name".utf8), condition: .absent, operationID: UUID())
        let second = try await remote.put(key: b, data: Data("secret-name".utf8), condition: .absent, operationID: UUID())
        do { _ = try await remote.put(key: a, data: Data(), condition: .matches("wrong"), operationID: UUID()); XCTFail() } catch StorageFailure.conflict {}
        let wrong = try wrapper(base, EncryptedDriveKey.generate(), directory.appendingPathComponent("wrong"))
        do { _ = try await wrong.head(key: a); XCTFail() } catch StorageFailure.integrity {}
        await base.transplant(b, to: a)
        do { _ = try await remote.head(key: a); XCTFail() } catch StorageFailure.integrity {}
        await base.corrupt(b, at: EncryptedObjectHeader.byteCount)
        do { _ = try await remote.read(key: b, range: 0..<second.size, validator: second.validator); XCTFail() } catch StorageFailure.integrity {}
        XCTAssertFalse(first.validator.isEmpty)
    }
    func testChangedRetryRejectedBeforeNonceReuseAndSaltIsDurable() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let base = EncryptedFixtureRemote(), key = EncryptedDriveKey.generate(), remote = try wrapper(base, key, directory)
        let operation = UUID(), path = "Drive/.clouddrive/v1/content/node/1/op"
        await base.failUploads(true)
        do { _ = try await remote.uploadContent(keyHint: path, size: 3, operationID: operation) { _ in Data("one".utf8) }; XCTFail() } catch StorageFailure.offline {}
        await base.failUploads(false)
        do { _ = try await remote.uploadContent(keyHint: path, size: 3, operationID: operation) { _ in Data("two".utf8) }; XCTFail() } catch StorageFailure.integrity {}
        let object = try await remote.uploadContent(keyHint: path, size: 3, operationID: operation) { _ in Data("one".utf8) }
        let bytes = try await remote.read(key: object.key, range: 0..<3, validator: object.validator)
        XCTAssertEqual(bytes.data, Data("one".utf8))
    }
    func testMarkerPreventsPlaintextFallbackAndExistingNamespaceConversion() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        try EncryptedDriveState.validate(directory: directory, binding: "drive", keyID: "key")
        XCTAssertThrowsError(try EncryptedDriveState.validate(directory: directory, binding: "drive", keyID: nil))
        XCTAssertThrowsError(try EncryptedDriveState.validate(directory: directory, binding: "other", keyID: "key"))
        try EncryptedDriveState.validate(directory: directory, binding: "drive", keyID: "key")
        let plain = directory.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("Namespace"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try EncryptedDriveState.validate(directory: plain, binding: "drive", keyID: "key"))
    }
    func testManagedEnginePublishesEncryptedNamespaceAndRestoresWithRecoveryKey() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let base = EncryptedFixtureRemote(), key = EncryptedDriveKey.generate(), remote = try wrapper(base, key, directory.appendingPathComponent("crypto"))
        let store = try NamespaceStore(directory: directory.appendingPathComponent("namespace"), binding: "encrypted", mode: .managed)
        let content = try ContentStore(directory: directory.appendingPathComponent("content")), cache = try RangeCache(directory: directory.appendingPathComponent("cache"))
        let engine = SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: "Drive", mode: .managed)
        let volume = try await store.volume(), node = try await store.create(parentID: volume.rootID, name: "private-name.txt", kind: .file)
        _ = try await engine.write(nodeID: node.id, offset: 0, data: Data("private file contents".utf8))
        try await engine.processPending()
        let raw = await base.allBytes()
        XCTAssertTrue(raw.allSatisfy { $0.range(of: Data("private-name".utf8)) == nil && $0.range(of: Data("private file contents".utf8)) == nil })
        let recovery = try EncryptedDriveRecoveryEnvelope.create(masterKey: key, keyID: EncryptedDriveKey.identifier(for: key))
        let recoveredKey = try recovery.envelope.recover(recoveryKey: recovery.recoveryKey)
        let recoveredRemote = try wrapper(base, recoveredKey, directory.appendingPathComponent("recovered-crypto"))
        let restored = try await NamespaceRecovery.restoreManaged(remote: recoveredRemote, prefix: "Drive", directory: directory.appendingPathComponent("restored"), binding: "encrypted")
        let restoredNode = try await restored.node(node.id); XCTAssertEqual(restoredNode.name, node.name)
        let backing = try XCTUnwrap(restoredNode.backing), tag = try XCTUnwrap(backing.validator)
        let bytes = try await recoveredRemote.read(key: backing.key, range: 0..<backing.size, validator: tag)
        XCTAssertEqual(bytes.data, Data("private file contents".utf8))
        await restored.close(); await store.close()
    }
    func testMissingPersistedUploadIntentNeverGeneratesNewSaltForExistingParts() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let base = EncryptedFixtureRemote(), key = EncryptedDriveKey.generate(), remote = try wrapper(base, key, directory)
        let operation = UUID(), path = "Drive/.clouddrive/v1/content/node/1/op"
        await base.failUploads(true)
        do { _ = try await remote.uploadContent(keyHint: path, size: 3, operationID: operation) { _ in Data("one".utf8) }; XCTFail() } catch StorageFailure.offline {}
        let intent = directory.appendingPathComponent(CoreFileIO.hash(Data((path + operation.uuidString).utf8))).appendingPathComponent("intent.json")
        try FileManager.default.removeItem(at: intent)
        await base.failUploads(false)
        do { _ = try await remote.uploadContent(keyHint: path, size: 3, operationID: operation) { _ in Data("one".utf8) }; XCTFail() } catch StorageFailure.integrity {}
        let stored = await base.allBytes(); XCTAssertTrue(stored.isEmpty)
    }

}
