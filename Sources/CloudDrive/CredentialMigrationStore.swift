import Foundation

struct StoredCredential<Value: Equatable>: Equatable {
    let value: Value
    let persisted: Bool
}

/// A legacy read is never mistaken for persistence in the new service.
/// Adding during migration is exclusive: an existing new value always wins.
struct CredentialMigrationStore<Value: Equatable> {
    let readCurrent: (Bool) throws -> Value?
    let readLegacy: (Bool) throws -> Value?
    let addCurrent: (Value) throws -> Bool
    let writeCurrent: (Value) throws -> Void
    let authorizeCreation: () throws -> Void

    func load(allowInteraction: Bool) throws -> StoredCredential<Value>? {
        if let value = try readCurrent(allowInteraction) {
            return StoredCredential(value: value, persisted: true)
        }
        guard let legacy = try readLegacy(allowInteraction) else { return nil }
        guard allowInteraction else { return StoredCredential(value: legacy, persisted: false) }
        try authorizeCreation()
        let added = try addCurrent(legacy)
        guard let current = try readCurrent(false) else {
            throw DriveError.message("The saved connection could not be confirmed in the new Keychain item. The original item was preserved. Retry Load Saved Connection.")
        }
        guard !added || current == legacy else {
            throw DriveError.message("The new Keychain item did not match the connection after migration. The original item was preserved; no persistent success was assumed.")
        }
        return StoredCredential(value: current, persisted: true)
    }

    func save(_ value: Value) throws {
        try authorizeCreation()
        try writeCurrent(value)
        guard try readCurrent(false) == value else {
            throw DriveError.message("The connection could not be confirmed after saving. Retry Load Saved Connection before reconnecting.")
        }
    }
}
