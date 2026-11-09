import Foundation
import CryptoKit

public enum EncryptedDriveKey {
    public static func generate() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    public static func identifier(for key: Data) -> String { SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() }
}

/// Recovery uses a generated 256-bit secret, never a human password fed into HKDF.
public struct EncryptedDriveRecoveryEnvelope: Codable, Sendable {
    public let version: Int
    public let keyID: String
    public let salt: Data
    public let sealedKey: Data
    public static func create(masterKey: Data, keyID: String) throws -> (envelope: Self, recoveryKey: String) {
        guard masterKey.count == 32, keyID == EncryptedDriveKey.identifier(for: masterKey) else { throw StorageFailure.integrity }
        let secret = EncryptedDriveKey.generate(), salt = EncryptedDriveKey.generate()
        let wrapping = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
            info: Data("CloudDrive recovery envelope v1".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(masterKey, using: wrapping, authenticating: Data(("v1:" + keyID).utf8))
        guard let combined = sealed.combined else { throw StorageFailure.integrity }
        return (Self(version: 1, keyID: keyID, salt: salt, sealedKey: combined), secret.base64EncodedString())
    }
    public func recover(recoveryKey: String) throws -> Data {
        guard version == 1, salt.count == 32, sealedKey.count == 60,
              let secret = Data(base64Encoded: recoveryKey), secret.count == 32 else { throw StorageFailure.integrity }
        do {
            let wrapping = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                info: Data("CloudDrive recovery envelope v1".utf8), outputByteCount: 32)
            let key = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedKey), using: wrapping, authenticating: Data(("v1:" + keyID).utf8))
            guard key.count == 32, EncryptedDriveKey.identifier(for: key) == keyID else { throw StorageFailure.integrity }
            return key
        } catch { throw StorageFailure.integrity }
    }
}

struct EncryptedObjectHeader: Sendable {
    static let byteCount = 104
    static let chunkSize = 1_048_576
    let size: Int64
    let salt: Data
    let context: Data
    let bytes: Data
    var chunks: Int64 { size == 0 ? 0 : (size - 1) / Int64(Self.chunkSize) + 1 }
    var encodedSize: Int64 { Int64(Self.byteCount) + size + chunks * 16 }
    static func integer(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * (count - 1 - $0))) })
    }
    static func number(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    static func key(_ master: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: salt,
            info: Data("CloudDrive encrypted object v1".utf8), outputByteCount: 32)
    }
    static func nonce(_ index: Int64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + integer(UInt64(index), count: 8))
    }
    static func create(size: Int64, salt: Data, context: Data, master: Data) throws -> Self {
        guard size >= 0, size <= 600_000_000_000, salt.count == 32, context.count == 32, master.count == 32 else { throw StorageFailure.invalidRange }
        var prefix = Data("CDENC001".utf8)
        prefix += integer(UInt64(chunkSize), count: 4); prefix += integer(1, count: 4)
        prefix += integer(UInt64(size), count: 8); prefix += salt; prefix += context
        let tag = try AES.GCM.seal(Data(), using: key(master, salt: salt), nonce: nonce(0), authenticating: prefix).tag
        return Self(size: size, salt: salt, context: context, bytes: prefix + tag)
    }
    static func parse(_ input: Data, context: Data, master: Data) throws -> Self {
        var data = Data(); data.append(input) // Transport Data may be a non-zero-index slice.
        guard data.count == byteCount, data.prefix(8) == Data("CDENC001".utf8),
              number(data.subdata(in: 8..<12)) == UInt64(chunkSize), number(data.subdata(in: 12..<16)) == 1,
              data.subdata(in: 56..<88) == context else { throw StorageFailure.integrity }
        let length = number(data.subdata(in: 16..<24)); guard length <= 600_000_000_000 else { throw StorageFailure.integrity }
        let header = try create(size: Int64(length), salt: data.subdata(in: 24..<56), context: context, master: master)
        do {
            _ = try AES.GCM.open(AES.GCM.SealedBox(nonce: nonce(0), ciphertext: Data(), tag: data.suffix(16)),
                using: key(master, salt: header.salt), authenticating: data.prefix(88))
        } catch { throw StorageFailure.integrity }
        return header
    }
    func plaintextRange(_ index: Int64) -> Range<Int64> {
        let start = index * Int64(Self.chunkSize); return start..<min(size, start + Int64(Self.chunkSize))
    }
    func ciphertextRange(_ index: Int64) -> Range<Int64> {
        let start = Int64(Self.byteCount) + index * Int64(Self.chunkSize + 16)
        return start..<(start + Int64(plaintextRange(index).count) + 16)
    }
    func aad(_ index: Int64) -> Data { bytes.prefix(88) + Self.integer(UInt64(index), count: 8) + Self.integer(UInt64(plaintextRange(index).count), count: 4) }
    func seal(_ data: Data, index: Int64, master: Data) throws -> Data {
        guard index >= 0, index < chunks, data.count == plaintextRange(index).count else { throw StorageFailure.integrity }
        let box = try AES.GCM.seal(data, using: Self.key(master, salt: salt), nonce: Self.nonce(index + 1), authenticating: aad(index))
        var encoded = Data(); encoded.append(box.ciphertext); encoded.append(box.tag); return encoded
    }
    func open(_ data: Data, index: Int64, master: Data) throws -> Data {
        guard index >= 0, index < chunks, data.count == ciphertextRange(index).count else { throw StorageFailure.integrity }
        do { return try AES.GCM.open(AES.GCM.SealedBox(nonce: Self.nonce(index + 1), ciphertext: data.dropLast(16), tag: data.suffix(16)),
            using: Self.key(master, salt: salt), authenticating: aad(index)) }
        catch { throw StorageFailure.integrity }
    }
}
