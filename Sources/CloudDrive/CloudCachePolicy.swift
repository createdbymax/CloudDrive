import Foundation

/// Let rclone evict only content it considers reproducible: never delete cache files ourselves.
enum CloudCachePolicy {
    static let arguments = ["--vfs-cache-mode", "full", "--vfs-cache-max-size", "5G",
        "--vfs-cache-min-free-space", "10G", "--vfs-cache-max-age", "1s", "--vfs-cache-poll-interval", "1s"]
    static func isActive(_ options: CacheOptions?) -> Bool {
        options?.maxAge == 1_000_000_000 && options?.pollInterval == 1_000_000_000
    }
    struct CacheOptions: Decodable, Equatable, Sendable {
        let maxAge: Int64
        let pollInterval: Int64
        enum CodingKeys: String, CodingKey { case maxAge = "CacheMaxAge", pollInterval = "CachePollInterval" }
    }
}
