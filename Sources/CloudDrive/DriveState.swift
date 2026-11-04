import Foundation
import CryptoKit

enum MountState: Equatable {
    case disconnected, checking, connected, unmounted, blocked
    var text: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .checking: return "Checking drive ownership…"
        case .connected: return "Finder drive connected"
        case .unmounted: return "Finder ejected; storage worker still running"
        case .blocked: return "Recovery needs attention"
        }
    }
}

enum UploadState: Equatable {
    case unknown, idle, active(queued: Int, uploading: Int), failed(Int), outOfSpace
    var text: String {
        switch self {
        case .unknown: return "Upload status unknown. Pending local data may remain."
        case .idle: return "Upload queue idle. This does not independently verify cloud files."
        case .active(let queued, let uploading): return "\(queued) waiting · \(uploading) uploading. Keep the app running."
        case .failed(let count): return "\(count) local cache errors. Pending data is retained."
        case .outOfSpace: return "Local staging space is exhausted. Preserve the cache and free space elsewhere."
        }
    }
}

struct VerificationReceipt: Equatable {
    let destinationFingerprint: String
    let fixture: String
    let byteCount: Int
    let sha256: String
    let verifiedAt: Date
    var text: String { "Passed: \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) fixture independently downloaded and SHA-256 matched at \(verifiedAt.formatted(date: .omitted, time: .shortened)). Other files remain unverified." }
}

struct BackendBinding {
    // Rclone appends a config hash when a remote is configured through environment overrides.
    static func matches(fs: String, cachePath: String, connection: Connection, cacheRoot: URL) -> Bool {
        guard let colon = fs.firstIndex(of: ":") else { return false }
        let name = String(fs[..<colon])
        guard name.range(of: "^bucket(?:\\{[A-Za-z0-9_-]+\\})?$", options: .regularExpression) != nil,
              String(fs[fs.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "\(connection.bucket)/\(connection.prefix)" else { return false }
        let expected = cacheRoot.appendingPathComponent("vfs").appendingPathComponent(name).appendingPathComponent(connection.bucket).appendingPathComponent(connection.prefix)
        return URL(fileURLWithPath: cachePath).standardizedFileURL.path == expected.standardizedFileURL.path
    }
}

extension Connection {
    var fingerprint: String { SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() }
    var workerEnvironment: [String: String] {
        // Do not inherit arbitrary RCLONE_* overrides, proxy settings or credential variables.
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        result["TMPDIR"] = NSTemporaryDirectory()
        result.merge(environment) { _, new in new }
        return result
    }
}
