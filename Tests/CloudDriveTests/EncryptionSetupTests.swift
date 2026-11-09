import XCTest
import CloudDriveCore
@testable import CloudDrive

@MainActor final class EncryptionSetupTests: XCTestCase {
    private let connection = Connection(endpoint: "https://encryption-fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "fixture", accessKey: "synthetic", secretKey: "synthetic")
    func testInterruptedKeySaveRetainsManagedIntentAndBlocksPlainWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appendingPathComponent("Remote")
        _ = try FixtureStorageRemote(directory: remote)
        let controller = NamespaceDriveController(root: root, engineBinary: root.appendingPathComponent("unused"), fixtureRemoteDirectory: remote)
        controller.legacySafetyCheck = { true }
        controller.beforeEncryptionKeySaveForTesting = { throw CocoaError(.userCancelled) }
        let key = EncryptedDriveKey.generate()
        await controller.prepareEncrypted(connection: connection, secret: .init(keyID: EncryptedDriveKey.identifier(for: key), key: key), recovering: false, legacySafe: true)
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertTrue(controller.encrypted); XCTAssertTrue(controller.ownsDestination)
        XCTAssertFalse(controller.hasSession)
        let replacement = NamespaceDriveController(root: root)
        replacement.configure(connection)
        XCTAssertTrue(replacement.encrypted); XCTAssertTrue(replacement.ownsDestination)
        XCTAssertEqual(replacement.mode, .managed)
        let marker = root.appendingPathComponent("Namespaces/" + connection.fingerprint + "/encryption-selection.json")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        XCTAssertEqual(value["recovering"] as? Bool, false)
    }
    func testWrongValidRecoveryKeyDoesNotPoisonSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remoteDirectory = root.appendingPathComponent("Remote")
        let remote = try FixtureStorageRemote(directory: remoteDirectory)
        let right = EncryptedDriveKey.generate(), wrong = EncryptedDriveKey.generate()
        let encrypted = try EncryptedStorageRemote(base: remote, masterKey: right, keyID: EncryptedDriveKey.identifier(for: right), prefix: "fixture", journalDirectory: root.appendingPathComponent("TestEncryption"))
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "volumeID": UUID().uuidString, "commitID": String(repeating: "a", count: 64)])
        _ = try await encrypted.put(key: "fixture/.clouddrive/v1/HEAD", data: bytes, condition: .absent, operationID: UUID())
        let controller = NamespaceDriveController(root: root, engineBinary: root.appendingPathComponent("unused"), fixtureRemoteDirectory: remoteDirectory)
        controller.legacySafetyCheck = { true }
        var reachedKeySave = false
        controller.beforeEncryptionKeySaveForTesting = { reachedKeySave = true; throw CocoaError(.userCancelled) }
        await controller.prepareEncrypted(connection: connection, secret: .init(keyID: EncryptedDriveKey.identifier(for: wrong), key: wrong), recovering: true, legacySafe: true)
        XCTAssertFalse(controller.error.isEmpty); XCTAssertFalse(controller.encrypted); XCTAssertFalse(reachedKeySave)
        await controller.prepareEncrypted(connection: connection, secret: .init(keyID: EncryptedDriveKey.identifier(for: right), key: right), recovering: true, legacySafe: true)
        XCTAssertTrue(reachedKeySave); XCTAssertTrue(controller.encrypted)
    }
    func testNewEncryptionRefusesExistingObjectsBeforeSavingKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remoteDirectory = root.appendingPathComponent("Remote")
        let remote = try FixtureStorageRemote(directory: remoteDirectory)
        _ = try await remote.put(key: "fixture/original.txt", data: Data("keep".utf8), condition: .absent, operationID: UUID())
        let controller = NamespaceDriveController(root: root, engineBinary: root.appendingPathComponent("unused"), fixtureRemoteDirectory: remoteDirectory)
        controller.legacySafetyCheck = { true }
        controller.beforeEncryptionKeySaveForTesting = { XCTFail("Must not save key for occupied prefix"); throw CocoaError(.userCancelled) }
        let key = EncryptedDriveKey.generate()
        await controller.prepareEncrypted(connection: connection, secret: .init(keyID: EncryptedDriveKey.identifier(for: key), key: key), recovering: false, legacySafe: true)
        XCTAssertFalse(controller.encrypted); XCTAssertFalse(controller.error.isEmpty)
        let retained = try await remote.head(key: "fixture/original.txt")
        XCTAssertEqual(retained?.size, 4)
    }
}
