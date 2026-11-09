import Foundation
import Security
import CloudDriveCore

struct DriveEncryptionSecret: Codable, Equatable {
    let keyID: String
    let key: Data
    func validate() throws {
        guard key.count == 32, EncryptedDriveKey.identifier(for: key) == keyID else {
            throw DriveError.message("The encrypted drive key does not match its identifier.")
        }
    }
}

/// Uses the existing bounded credential session: locked Keychain calls cannot
/// freeze the UI and background reconnects never initiate authentication UI.
@MainActor enum DriveEncryptionKeyStore {
    private static var sessions: [String: CredentialSession<DriveEncryptionSecret>] = [:]
    static func session(binding: String) -> CredentialSession<DriveEncryptionSecret> {
        if let value = sessions[binding] { return value }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CloudDrive.EncryptedDrive.v1", kSecAttrAccount as String: binding]
        let value = CredentialSession<DriveEncryptionSecret>(read: { interactive in
            var q = query
            q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
            var result: CFTypeRef?
            let code = SecItemCopyMatching(q as CFDictionary, &result)
            if code == errSecItemNotFound { return nil }
            guard code == errSecSuccess, let bytes = result as? Data else { throw CredentialFailure.authorizationNeeded }
            let secret = try JSONDecoder().decode(DriveEncryptionSecret.self, from: bytes)
            try secret.validate(); return secret
        }, write: { secret in
            try secret.validate()
            var q = query
            q[kSecValueData as String] = try JSONEncoder().encode(secret)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let code = SecItemAdd(q as CFDictionary, nil)
            if code == errSecDuplicateItem {
                // Never silently rotate a key or replace access to existing data.
                var lookup = query; lookup[kSecReturnData as String] = true
                lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
                var result: CFTypeRef?
                guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
                      let bytes = result as? Data,
                      try JSONDecoder().decode(DriveEncryptionSecret.self, from: bytes) == secret else {
                    throw DriveError.message("A different encryption key is saved for this connection. Use a new empty prefix; existing keys were preserved.")
                }
            } else if code != errSecSuccess { throw CredentialFailure.authorizationNeeded }
        })
        sessions[binding] = value; return value
    }
}

/// This export is a bearer recovery kit, not a password-protected backup. The
/// UI explicitly explains that possessing the file permits decrypting the drive.
struct DriveRecoveryKit: Codable {
    let version: Int
    let envelope: EncryptedDriveRecoveryEnvelope
    let recoveryKey: String
    func secret() throws -> DriveEncryptionSecret {
        guard version == 1 else { throw DriveError.message("Unsupported recovery kit version.") }
        let key = try envelope.recover(recoveryKey: recoveryKey)
        let secret = DriveEncryptionSecret(keyID: EncryptedDriveKey.identifier(for: key), key: key)
        try secret.validate(); return secret
    }
}
