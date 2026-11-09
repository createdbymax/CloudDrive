import Foundation
import Security
import Darwin

/// Sandboxed FSKit clients can connect to a Unix socket in their shared app
/// group. A security-scoped directory alone does not grant Unix socket IPC.
public enum NamespaceResourceLocation {
    public static func sharedBase() throws -> URL {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String],
              groups.contains(team + ".cd"),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: team + ".cd") else {
            throw POSIXError(.EPERM)
        }
        return container.appendingPathComponent("r", isDirectory: true)
    }

    public static func fixtureBase() -> URL {
        URL(fileURLWithPath: "/tmp/clouddrive-" + String(getuid()), isDirectory: true)
    }

    public static func resource(sessionID: UUID, fixture: Bool = false) throws -> URL {
        let base: URL
        if fixture { base = (try? sharedBase()) ?? fixtureBase() }
        else { base = try sharedBase() }
        return try resource(base: base, sessionID: sessionID)
    }

    static func resource(base: URL, sessionID: UUID) throws -> URL {
        let resource = base.appendingPathComponent(String(sessionID.uuidString.prefix(16)), isDirectory: true)
        guard resource.appendingPathComponent("owner.sock").path.utf8.count < 104 else { throw POSIXError(.ENAMETOOLONG) }
        return resource
    }
}
