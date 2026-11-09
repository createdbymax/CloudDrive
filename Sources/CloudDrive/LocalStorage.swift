import Foundation
import Darwin

struct LocalStorageSnapshot: Equatable, Sendable {
    let dataCacheBytes: Int64
    let otherBytes: Int64
    let freeBytes: Int64?
    let complete: Bool
    let measuredAt: Date
}

/// Metadata-only scan of local app storage. Directory descriptors prevent symlink
/// traversal; mountpoints, including Drive, are never entered. No cloud reads.
enum LocalStorageScanner {
    static func scan(root: URL, cache: URL, maxEntries: Int = 20_000, seconds: Double = 1) -> LocalStorageSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        var data: Int64 = 0, other: Int64 = 0, count = 0, complete = true
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return LocalStorageSnapshot(dataCacheBytes: 0, otherBytes: 0, freeBytes: nil, complete: false, measuredAt: Date())
        }
        defer { close(descriptor) }
        var rootStat = stat()
        guard fstat(descriptor, &rootStat) == 0 else {
            return LocalStorageSnapshot(dataCacheBytes: 0, otherBytes: 0, freeBytes: nil, complete: false, measuredAt: Date())
        }
        let prefix = root.standardizedFileURL.path + "/"
        let cachePath = cache.standardizedFileURL.appendingPathComponent("vfs").path
        let dataRelative = cachePath.hasPrefix(prefix) ? String(cachePath.dropFirst(prefix.count)) : ""
        func walk(_ fd: Int32, relative: String, depth: Int) {
            guard depth <= 32, let directory = fdopendir(dup(fd)) else { complete = false; return }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                guard count < maxEntries, ProcessInfo.processInfo.systemUptime - start < seconds else { complete = false; return }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                count += 1
                let child = relative.isEmpty ? name : relative + "/" + name
                // Never stat/traverse either filesystem mount. It can block, hydrate or be stale.
                if child == "Drive" || child == "Instant Drive" { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { complete = false; continue }
                guard info.st_dev == rootStat.st_dev else { complete = false; continue }
                let bytes = Int64(info.st_blocks) * 512
                if !dataRelative.isEmpty && (child == dataRelative || child.hasPrefix(dataRelative + "/")) { data += bytes }
                else { other += bytes }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard childFD >= 0 else { complete = false; continue }
                    walk(childFD, relative: child, depth: depth + 1)
                    close(childFD)
                    if !complete && (count >= maxEntries || ProcessInfo.processInfo.systemUptime - start >= seconds) { return }
                }
            }
        }
        walk(descriptor, relative: "", depth: 0)
        var volume = statvfs()
        let free: Int64?
        if fstatvfs(descriptor, &volume) == 0 {
            let value = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_frsize))
            free = !value.overflow && value.partialValue <= UInt64(Int64.max) ? Int64(value.partialValue) : nil
        } else { free = nil }
        return LocalStorageSnapshot(dataCacheBytes: data, otherBytes: other, freeBytes: free, complete: complete, measuredAt: Date())
    }
}
