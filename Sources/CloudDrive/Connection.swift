import Foundation
import Security

struct Connection: Codable, Equatable {
    var endpoint = ""
    var bucket = ""
    var prefix = "clouddrive"
    var accessKey = ""
    var secretKey = ""

    func validate() throws {
        guard let u = URLComponents(string: endpoint), u.scheme == "https", let host = u.host,
              host.hasSuffix(".r2.cloudflarestorage.com"), u.user == nil, u.password == nil,
              u.port == nil, u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/" else {
            throw DriveError.message("Enter the HTTPS R2 S3 endpoint from Cloudflare (not a public bucket URL).")
        }
        guard bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil else {
            throw DriveError.message("Enter a valid bucket name.")
        }
        guard !prefix.isEmpty, prefix.count <= 128, prefix.range(of: "^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil else {
            throw DriveError.message("Use a dedicated prefix with letters, numbers, hyphens or underscores. Bucket root is disabled in this prototype.")
        }
        guard !accessKey.isEmpty, !secretKey.isEmpty, !accessKey.contains("\n"), !secretKey.contains("\n") else {
            throw DriveError.message("Enter your R2 access key and secret key.")
        }
    }
    var remote: String { "bucket:\(bucket)/\(prefix)" }
    // Stable namespace and cache identity; never share a cache between different remotes.
    var identity: String { endpoint + "/" + bucket + "/" + prefix }
    var environment: [String: String] {
        ["RCLONE_CONFIG_BUCKET_TYPE": "s3", "RCLONE_CONFIG_BUCKET_PROVIDER": "Cloudflare",
         "RCLONE_CONFIG_BUCKET_ENDPOINT": endpoint, "RCLONE_CONFIG_BUCKET_REGION": "auto",
         "RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID": accessKey, "RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY": secretKey,
         "RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET": "true"]
    }
}

enum DriveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum CredentialFailure: LocalizedError {
    case authorizationNeeded, operationPending
    var errorDescription: String? {
        switch self {
        case .authorizationNeeded: return "Saved connection needs macOS Keychain approval. Choose Load Saved Connection, then answer the macOS prompt."
        case .operationPending: return "macOS is still handling a Keychain request. Clear its prompt before retrying; no new request was sent."
        }
    }
}

enum Credentials {
    // Persistent compatibility identifiers retain saved connections across the rename.
    private static let currentService = "local.bucketdrive.r2.v2"
    private static let legacyService = "local.bucketdrive.r2"
    private static let migration = CredentialMigrationStore<Connection>(
        readCurrent: { try read(service: currentService, allowInteraction: $0) },
        readLegacy: { try read(service: legacyService, allowInteraction: $0) },
        addCurrent: { value in try withoutPrompts { try add(value, service: currentService) } },
        writeCurrent: { value in try withoutPrompts { try write(value) } },
        authorizeCreation: requireStableSignature
    )
    private static let session = CredentialSession<StoredCredential<Connection>>(
        read: { try migration.load(allowInteraction: $0) },
        write: { try migration.save($0.value) },
        shouldCache: { $0.persisted }
    )
    static func loadBounded(allowInteraction: Bool = false) async throws -> Connection? {
        try await session.load(allowInteraction: allowInteraction)?.value
    }
    static func saveBounded(_ connection: Connection) async throws {
        try await session.save(StoredCredential(value: connection, persisted: true))
    }
    // Legacy macOS Keychain compatibility. The session serializes these calls.
    private static func withoutPrompts<T>(_ body: () throws -> T) throws -> T {
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw CredentialFailure.authorizationNeeded }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "primary"]
    }
    private static func read(service: String, allowInteraction: Bool) throws -> Connection? {
        if !allowInteraction { return try withoutPrompts { try readConnection(service: service) } }
        return try readConnection(service: service)
    }
    private static func readConnection(service: String) throws -> Connection? {
        var q = query(service: service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "read")
        guard let data = result as? Data else { throw DriveError.message("Keychain returned no connection data.") }
        let connection = try JSONDecoder().decode(Connection.self, from: data)
        try connection.validate()
        return connection
    }
    /// Default ACL only. A duplicate must never replace a newer authoritative value during migration.
    private static func add(_ connection: Connection, service: String) throws -> Bool {
        var q = query(service: service)
        q[kSecValueData as String] = try JSONEncoder().encode(connection)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        try check(status, operation: "save")
        return true
    }
    private static func write(_ connection: Connection) throws {
        let data = try JSONEncoder().encode(connection)
        let q = query(service: currentService)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            guard try add(connection, service: currentService) else {
                throw DriveError.message("Another connection appeared while saving. Load Saved Connection before retrying.")
            }
        } else { try check(status, operation: "update") }
    }
    private static func check(_ status: OSStatus, operation: String) throws {
        if status == errSecInteractionNotAllowed || status == errSecInteractionRequired || status == errSecAuthFailed {
            throw CredentialFailure.authorizationNeeded
        }
        guard status == errSecSuccess else { throw DriveError.message("Keychain \(operation) failed (\(status)).") }
    }
    private static func requireStableSignature() throws {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              values[kSecCodeInfoIdentifier as String] as? String == "local.bucketdrive.app",
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty else {
            throw DriveError.message("Use a certificate-signed CloudDrive build to save or migrate the connection. The original Keychain item was preserved.")
        }
    }
}
