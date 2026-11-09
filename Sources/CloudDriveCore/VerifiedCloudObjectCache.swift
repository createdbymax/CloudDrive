import Foundation
import Darwin

/// Small reads of packed writeback objects share one fully verified fetch.
/// Entries are immutable, validator-bound and disposable; they never prove publication.
actor VerifiedCloudObjectCache {
    private struct Key: Hashable, Codable {
        let path: String
        let size: Int64
        let validator: String
        let checksum: String
    }
    private struct Entry { let data: Data; var accessed: UInt64 }
    private struct Fetch { let id: UUID; let task: Task<Data, Error> }
    private let disk: VerifiedObjectDiskCache?
    private let maximumBytes: Int
    private let maximumFetches: Int
    private var entries: [Key: Entry] = [:]
    private var fetching: [Key: Fetch] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0

    init(maximumBytes: Int = 64 * 1024 * 1024, directory: URL? = nil,
         maximumDiskBytes: Int = 1024 * 1024 * 1024, minimumFreeBytes: Int64 = 256 * 1024 * 1024,
         maximumFetches: Int = 8) {
        self.maximumBytes = min(64 * 1024 * 1024, max(0, maximumBytes))
        self.maximumFetches = min(24, max(1, maximumFetches))
        disk = directory.flatMap { VerifiedObjectDiskCache(directory: $0, maximumBytes: maximumDiskBytes, minimumFreeBytes: minimumFreeBytes) }
    }

    private func diskName(_ key: Key) -> String {
        // Separate path prefix permits removal of every validator/generation after restart.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return CoreFileIO.hash(Data(key.path.utf8)) + "-" + CoreFileIO.hash((try? encoder.encode(key)) ?? Data())
    }

    func read(key path: String, size: Int64, validator: String, checksum: String, remote: any StorageRemote) async throws -> Data {
        guard size >= 0, size <= 8 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        let key = Key(path: path, size: size, validator: validator, checksum: checksum)
        while true {
            try Task.checkCancellation()
            if var entry = entries[key] {
                clock &+= 1; entry.accessed = clock; entries[key] = entry
                return entry.data
            }
            let fetch: Fetch
            if let existing = fetching[key] { fetch = existing }
            else {
                // Bound transient response buffers as well as retained cache bytes.
                if fetching.count >= maximumFetches, let other = fetching.values.first {
                    _ = try? await other.task.value
                    // Its owner removes the slot on completion; yield so a ready
                    // task cannot monopolize this actor while waiting for that owner.
                    await Task.yield()
                    continue
                }
                let name = diskName(key)
                let cached = disk?.read(name: name, size: Int(size), checksum: checksum)
                let task = Task {
                    if let cached { return cached }
                    let value = try await remote.read(key: path, range: 0..<size, validator: validator)
                    guard value.offset == 0, value.totalSize == size, value.data.count == size,
                          value.validator == validator, CoreFileIO.hash(value.data) == checksum else { throw StorageFailure.integrity }
                    return value.data
                }
                fetch = Fetch(id: UUID(), task: task); fetching[key] = fetch
            }
            do {
                let data = try await fetch.task.value
                if fetching[key]?.id == fetch.id {
                    fetching.removeValue(forKey: key)
                    disk?.store(name: diskName(key), data: data)
                    if data.count <= maximumBytes {
                        while bytes > maximumBytes - data.count,
                              let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed }) {
                            bytes -= oldest.value.data.count; entries.removeValue(forKey: oldest.key)
                        }
                        clock &+= 1; entries[key] = Entry(data: data, accessed: clock); bytes += data.count
                    }
                }
                try Task.checkCancellation()
                return data
            } catch {
                if fetching[key]?.id == fetch.id { fetching.removeValue(forKey: key) }
                throw error
            }
        }
    }

    func remove(key path: String) {
        disk?.remove(prefix: CoreFileIO.hash(Data(path.utf8)) + "-")
        for key in Array(entries.keys) where key.path == path {
            if let entry = entries.removeValue(forKey: key) { bytes -= entry.data.count }
        }
    }
}

/// Disposable clean data only. All IO is relative to a pinned private directory fd;
/// replacing its pathname cannot redirect cache operations into another directory.
private final class VerifiedObjectDiskCache {
    private var fd: Int32
    private let identity: CoreDirectoryIdentity
    private let maximumBytes: Int64
    private let minimumFreeBytes: Int64
    private var files: [String: (size: Int64, age: UInt64)] = [:]
    private var total: Int64 = 0
    private var age: UInt64 = 0
    private let maximumFiles = 4096

    init?(directory: URL, maximumBytes: Int, minimumFreeBytes: Int64) {
        guard maximumBytes > 0 else { return nil }
        let parent = directory.deletingLastPathComponent()
        let parentIdentity: CoreDirectoryIdentity
        do { parentIdentity = try CoreDirectoryIdentity(parent) } catch { return nil }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { return nil }
        defer { close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_dev == parentIdentity.device,
              parentInfo.st_ino == parentIdentity.inode else { return nil }
        let name = directory.lastPathComponent
        guard mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else { return nil }
        do { identity = try CoreDirectoryIdentity(directory) } catch { return nil }
        fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        self.maximumBytes = Int64(maximumBytes); self.minimumFreeBytes = max(0, minimumFreeBytes)
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == identity.device, opened.st_ino == identity.inode else { close(fd); fd = -1; return nil }
        // One bounded startup inventory. There is never a directory scan per read.
        let listing = dup(fd)
        guard listing >= 0 else { close(fd); fd = -1; return nil }
        guard let iterator = fdopendir(listing) else { close(listing); close(fd); fd = -1; return nil }
        defer { closedir(iterator) }
        var count = 0
        while let entry = readdir(iterator) {
            count += 1
            // An unexpectedly huge directory disables this optional tier.
            guard count <= 8192 else { close(fd); fd = -1; return nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard Self.validName(name) else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Self.regular(info), info.st_size <= 8 * 1024 * 1024 else { continue }
            age &+= 1; files[name] = (max(4096, Int64(info.st_blocks) * 512), age); total += max(4096, Int64(info.st_blocks) * 512)
        }
        evict(reserving: 0)
    }
    deinit { if fd >= 0 { close(fd) } }
    private static func validName(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        return parts.count == 2 && parts.allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }
    }
    private static func regular(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o077 == 0 && info.st_size >= 0
    }
    private func available() -> Bool { (try? identity.validate()) != nil }
    private func discard(_ name: String) {
        if let file = files.removeValue(forKey: name) { total -= file.size }
        _ = unlinkat(fd, name, 0)
    }
    private func evict(reserving size: Int64) {
        while total > maximumBytes - size || files.count >= maximumFiles {
            guard let oldest = files.min(by: { $0.value.age < $1.value.age })?.key else { break }
            discard(oldest)
        }
    }
    func read(name: String, size: Int, checksum: String) -> Data? {
        guard available(), files[name] != nil else { return nil }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { discard(name); return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, Self.regular(info), info.st_size == size else { discard(name); return nil }
        var data = Data(count: size)
        let success = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < size {
                let n = Darwin.read(file, buffer.baseAddress!.advanced(by: offset), size - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }; offset += n
            }
            return true
        }
        guard success, CoreFileIO.hash(data) == checksum else { discard(name); return nil }
        age &+= 1; files[name]?.age = age
        return data
    }
    func store(name: String, data: Data) {
        let reservation = max(4096, ((Int64(data.count) + 4095) / 4096) * 4096)
        guard available(), reservation <= maximumBytes else { return }
        // Hits need no rewrite; disk reads already checked length and SHA-256.
        guard files[name] == nil else { return }
        evict(reserving: reservation)
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return }
        let free = UInt64(fs.f_bavail).multipliedReportingOverflow(by: UInt64(fs.f_bsize))
        guard !free.overflow, free.partialValue >= UInt64(minimumFreeBytes) + UInt64(reservation) else { return }
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { return }
        // A partial/crashed write is harmless: every future disk hit hashes all bytes.
        let success = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }; offset += n
            }
            return true
        }
        let closed = close(file) == 0
        guard success && closed else { _ = unlinkat(fd, name, 0); return }
        age &+= 1; files[name] = (reservation, age); total += reservation
    }
    func remove(prefix: String) {
        guard available() else { return }
        for name in Array(files.keys) where name.hasPrefix(prefix) { discard(name) }
    }
}
