import Foundation
import Darwin

/// Let rclone evict only content it considers reproducible: never delete cache files ourselves.
enum CloudCachePolicy {
    static let arguments = ["--vfs-cache-mode", "full", "--vfs-cache-max-size", "5G",
        "--vfs-cache-min-free-space", "10G", "--vfs-cache-max-age", "1s", "--vfs-cache-poll-interval", "1s"]
    static func writebackCache(beside legacy: URL) -> URL {
        legacy.appendingPathExtension("writeback-v1")
    }

    /// Called under the app's owner lock, after retiring both the old worker and its intent.
    /// An older binary can safely use its original path without opening punched payloads.
    static func prepareWritebackCache(legacy: URL) throws -> URL {
        let parent = legacy.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = try privateDirectory(parent)
        defer { close(directory) }
        func exists(_ name: String) throws -> Bool {
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                      info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
                return true
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return false
        }
        let target = writebackCache(beside: legacy)
        let hasLegacy = try exists(legacy.lastPathComponent)
        if try exists(target.lastPathComponent) {
            guard !hasLegacy else {
                throw DriveError.message("Two cache versions contain drive state. Both were preserved. Recover the older session before reconnecting.")
            }
            return target
        }
        let result = hasLegacy
            ? renameatx_np(directory, legacy.lastPathComponent, directory, target.lastPathComponent, UInt32(RENAME_EXCL))
            : mkdirat(directory, target.lastPathComponent, 0o700)
        guard result == 0, fsync(directory) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return target
    }

    /// Size the local write window from the actual cache volume, including external volumes.
    /// Leave space for filesystem bookkeeping and other transfers on a nearly full Mac.
    static func spillWindowMiB(availableBytes: Int64) -> Int64 {
        let chunkMiB: Int64 = 4
        let affordableChunks = max(0, availableBytes) / (8 * chunkMiB * 1_048_576)
        return min(256, max(8, affordableChunks * chunkMiB))
    }

    static func writebackArguments(for connection: Connection, cache: URL) throws -> [String] {
        let values = try cache.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacity else {
            throw DriveError.message("CloudDrive could not read the free space on its cache volume.")
        }
        return ["--vfs-spill-prefix", ".clouddrive-spill-" + connection.fingerprint,
                "--vfs-spill-window", "\(spillWindowMiB(availableBytes: Int64(available)))Mi"]
    }

    static func isActive(_ options: CacheOptions?) -> Bool {
        options?.maxAge == 1_000_000_000 && options?.pollInterval == 1_000_000_000
    }
    struct CacheOptions: Decodable, Equatable, Sendable {
        let maxAge: Int64
        let pollInterval: Int64
        let moveJournal: String?
        let spillPrefix: String?
        let spillWindow: Int64?
        enum CodingKeys: String, CodingKey { case maxAge = "CacheMaxAge", pollInterval = "CachePollInterval", moveJournal = "MoveJournal", spillPrefix = "SpillPrefix", spillWindow = "SpillWindow" }
    }
}
