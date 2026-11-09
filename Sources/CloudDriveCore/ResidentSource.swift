import Foundation
import Darwin

/// A direct upload retains the selected original and its identity, not a second
/// payload copy. Each ranged read revalidates the open descriptor before and after I/O.
public struct ResidentSourceIdentity: Codable, Equatable, Sendable {
    public let url: URL
    public let bookmark: Data?
    public let device: Int64
    public let inode: UInt64
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64
    public static func capture(url: URL) throws -> Self {
        let url = url.standardizedFileURL
        guard url.isFileURL, url == url.resolvingSymlinksInPath() else { throw StorageFailure.integrity }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageFailure.notFound }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw StorageFailure.integrity }
        return Self(url: url, bookmark: try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil),
                    device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                    modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                    changeSeconds: Int64(info.st_ctimespec.tv_sec), changeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
    public func read(range: Range<Int64>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= size, range.count <= 67_108_864 else { throw StorageFailure.invalidRange }
        var resolved = url
        if let bookmark {
            var stale = false
            resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw StorageFailure.notFound }
        }
        let scoped = resolved.startAccessingSecurityScopedResource(); defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageFailure.notFound }; defer { Darwin.close(fd) }
        try validate(fd)
        var data = Data(count: range.count)
        try data.withUnsafeMutableBytes { bytes in
            var received = 0
            while received < bytes.count {
                let count = pread(fd, bytes.baseAddress!.advanced(by: received), bytes.count - received, range.lowerBound + Int64(received))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StorageFailure.integrity }; received += count
            }
        }
        try validate(fd); return data
    }
    private func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              Int64(info.st_dev) == device, UInt64(info.st_ino) == inode, info.st_size == size,
              info.st_mtimespec.tv_sec == modificationSeconds, info.st_mtimespec.tv_nsec == modificationNanoseconds,
              info.st_ctimespec.tv_sec == changeSeconds, info.st_ctimespec.tv_nsec == changeNanoseconds else { throw StorageFailure.integrity }
    }
}
