#if DEBUG
import CloudDriveCore
import CryptoKit
import Darwin
import Foundation

extension NativeR2Qualification {
    private static let largeFixtureSize: Int64 = 224 * 1_048_576
    private static let largeFixtureName = "finder-payload.bin"

    /// The test driver chooses only a UUID. All paths stay under the signed app’s
    /// own qualification directory. Its APFS disk image has a hard volume limit.
    private static func boundedContainer(work: URL) throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["CLOUDDRIVE_BOUNDED_FIXTURE_ID"],
              let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { throw POSIXError(.EINVAL) }
        let folder = work.deletingLastPathComponent().appendingPathComponent("Bounded-" + value, isDirectory: true)
        var info = stat()
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == folder.standardizedFileURL.path,
              lstat(folder.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
        return folder
    }

    static func boundedState(work: URL) throws -> URL {
        let fixture = try boundedContainer(work: work)
        let volume = fixture.appendingPathComponent("CacheVolume", isDirectory: true)
        var mounted = statfs(), parent = statfs()
        guard volume.resolvingSymlinksInPath().path == volume.path,
              statfs(volume.path, &mounted) == 0, statfs(fixture.path, &parent) == 0,
              mounted.f_fsid.val.0 != parent.f_fsid.val.0 || mounted.f_fsid.val.1 != parent.f_fsid.val.1 else { throw POSIXError(.EXDEV) }
        let kind = withUnsafeBytes(of: mounted.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let total = UInt64(mounted.f_bsize) * UInt64(mounted.f_blocks)
        guard kind == "apfs", total > 64 * 1_048_576, total <= 160 * 1_048_576 else { throw POSIXError(.EINVAL) }
        return volume.appendingPathComponent("State", isDirectory: true)
    }

    static func boundedExercise(work: URL, mount: URL) async throws {
        let fixture = try boundedContainer(work: work)
        let source = fixture.appendingPathComponent(largeFixtureName)
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size == largeFixtureSize, info.st_blocks * 512 >= largeFixtureSize else { throw POSIXError(.EINVAL) }
        // Finder is driven by the outer harness so its timing and result can be
        // observed even if the signed owner stops responding inside a callback.
        let ready = try JSONEncoder().encode(["mount": mount.path, "work": work.path])
        try ready.write(to: fixture.appendingPathComponent("ready.json"), options: .withoutOverwriting)
        let end = ContinuousClock.now.advanced(by: .seconds(1200))
        while !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("finder-copied").path) {
            if FileManager.default.fileExists(atPath: fixture.appendingPathComponent("finder-failed").path) { throw POSIXError(.EIO) }
            guard ContinuousClock.now < end else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    static func boundedVerify(work: URL, client: UnixSocketRPCClient, remote: S3StorageRemote, scope: String) async throws -> String {
        let fixture = try boundedContainer(work: work)
        guard let volume = try await client.call(.init(operation: "volume")).volume,
              let file = try await client.call(.init(operation: "lookup", parentID: volume.rootID, name: largeFixtureName)).node,
              let backing = file.backing, backing.key.hasPrefix(scope + "/.clouddrive/v1/content/"),
              backing.size == largeFixtureSize, let validator = backing.validator,
              let head = try await remote.head(key: backing.key), head.size == largeFixtureSize,
              head.validator == validator else { throw StorageFailure.integrity }
        var digest = SHA256()
        let batch = Int64(4 * 1_048_576)
        for offset in stride(from: Int64(0), to: largeFixtureSize, by: Int(batch)) {
            let range = offset..<min(offset + batch, largeFixtureSize)
            let chunk = try await remote.read(key: backing.key, range: range, validator: validator)
            guard chunk.offset == offset, chunk.totalSize == largeFixtureSize, chunk.validator == validator,
                  chunk.data.count == range.count else { throw StorageFailure.integrity }
            digest.update(data: chunk.data)
        }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = try String(contentsOf: fixture.appendingPathComponent("source.sha256"), encoding: .utf8)
        guard hex == expected else { throw StorageFailure.integrity }
        return hex
    }
}
#endif
