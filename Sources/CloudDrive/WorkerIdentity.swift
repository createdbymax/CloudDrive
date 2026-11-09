import Foundation
import Darwin
import CryptoKit

struct OwnershipError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// A PID is an address that the kernel reuses, not an ownership credential.
struct ProcessIdentity: Codable, Equatable {
    var pid: Int32
    var startSeconds: UInt64
    var startMicroseconds: UInt64
    var uid: UInt32
    var executablePath: String

    static func capture(pid: Int32) throws -> ProcessIdentity {
        guard pid > 1 else { throw OwnershipError("Invalid worker process identifier.") }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        guard count == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid() else {
            throw OwnershipError("Cannot establish ownership of the worker process.")
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw OwnershipError("Cannot identify the worker executable.")
        }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec, uid: info.pbi_uid,
            executablePath: String(cString: path))
    }

    func matchesRunningProcess() -> Bool { (try? Self.capture(pid: pid)) == self }

    /// A terminated child may remain as a zombie until Foundation reaps it.
    /// Treat only that exact recorded child (or a vacant PID) as exited.
    var hasExited: Bool {
        if kill(pid, 0) == -1, errno == ESRCH { return true }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        return count == MemoryLayout.size(ofValue: info) && info.pbi_uid == uid &&
            info.pbi_start_tvsec == startSeconds && info.pbi_start_tvusec == startMicroseconds &&
            info.pbi_status == SZOMB
    }
}

struct WorkerRecord: Codable, Equatable {
    var version: Int = 1
    var sessionID: UUID
    var process: ProcessIdentity
    var executableSHA256: String
    var destinationFingerprint: String
    var cachePath: String
    var mountPath: String
    var nfsPort: Int
    var controlPort: Int
    var controlToken: String
    var expectedRemote: String
    var observedFS: String? = nil
    var observedCachePath: String? = nil
    var mountID: String? = nil
    // Optional for records created by older builds. An interrupted or failed
    // unmount can temporarily disappear from macOS mount-table snapshots.
    var appDetachConfirmed: Bool? = nil
    var appDetachUncertain: Bool? = nil

    func validate(binary: URL, destinationFingerprint: String, cachePath: String, mountPath: String, requireRunning: Bool = true) throws {
        try validateShape()
        guard process.executablePath == binary.path else {
            throw OwnershipError("This worker was started by another CloudDrive build. Quit this app and reopen the build that started it to recover and eject. Worker and cache were preserved.")
        }
        guard self.destinationFingerprint == destinationFingerprint, self.cachePath == cachePath,
              self.mountPath == mountPath,
              (!requireRunning || process.matchesRunningProcess()), try Self.digest(binary) == executableSHA256 else {
            throw OwnershipError("Stored worker identity does not match this connection. No process was adopted or signaled.")
        }
    }

    /// Session ownership survives replacement of the app bundle. Callers must also
    /// authenticate the control endpoint and verify its PID, remote and cache binding.
    func validateSession(destinationFingerprint: String, cachePath: String, mountPath: String, requireRunning: Bool = true) throws {
        try validateShape()
        guard self.destinationFingerprint == destinationFingerprint, self.cachePath == cachePath,
              self.mountPath == mountPath, !requireRunning || process.matchesRunningProcess() else {
            throw OwnershipError("Stored worker session does not match this connection. No process was adopted or signaled.")
        }
    }

    func validateShape() throws {
        guard version == 1, process.pid > 1, process.uid == getuid(),
              !process.executablePath.isEmpty, process.executablePath.hasPrefix("/"),
              executableSHA256.count == 64, executableSHA256.allSatisfy({ $0.isHexDigit }),
              !destinationFingerprint.isEmpty, !expectedRemote.isEmpty,
              cachePath.hasPrefix("/"), mountPath.hasPrefix("/"),
              (1024...65535).contains(nfsPort), (1024...65535).contains(controlPort),
              nfsPort != controlPort, controlToken.utf8.count >= 32 else {
            throw OwnershipError("Worker state is malformed or uses an unsupported format. Pending cache was preserved.")
        }
    }

    static func digest(_ binary: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: binary)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct MountEntry: Equatable {
    var path: String
    var source: String
    var type: String
    var id: String
}

enum MountInspector {
    /// Read cached kernel mount metadata. Never stat the possibly hung NFS path.
    static func snapshot() throws -> [MountEntry] {
        for _ in 0..<4 {
            let count = getfsstat(nil, 0, MNT_NOWAIT)
            guard count >= 0 else { throw OwnershipError("Cannot inspect the Mac's mount table.") }
            var records: [statfs] = Array(repeating: statfs(), count: Int(count) + 16)
            let actual = records.withUnsafeMutableBufferPointer { buffer in
                getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            guard actual >= 0 else { throw OwnershipError("Cannot inspect the Mac's mount table.") }
            if actual >= records.count { continue }
            return records.prefix(Int(actual)).map(entry)
        }
        throw OwnershipError("Mount table changed repeatedly. Retry the operation.")
    }

    static func entry(_ record: statfs) -> MountEntry {
        var value = record
        let path = withUnsafePointer(to: &value.f_mntonname) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        let source = withUnsafePointer(to: &value.f_mntfromname) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        let type = withUnsafePointer(to: &value.f_fstypename) { p in p.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        return MountEntry(path: path, source: source, type: type,
            id: "\(value.f_fsid.val.0):\(value.f_fsid.val.1)")
    }

    static func exactEntry(at path: String, entries: [MountEntry]) -> MountEntry? {
        entries.first { $0.path == path }
    }

    static func validateOwnedMount(record: WorkerRecord, entries: [MountEntry]) throws -> Bool {
        guard let entry = exactEntry(at: record.mountPath, entries: entries) else { return false }
        guard entry.type == "nfs", entry.source == "127.0.0.1:/",
              let id = record.mountID, entry.id == id else {
            throw OwnershipError("The volume at this location is not the recorded CloudDrive mount. It was left untouched.")
        }
        return true
    }
}

func privateDirectory(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw OwnershipError("Cannot open the private CloudDrive state directory.") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFDIR else {
        close(descriptor); throw OwnershipError("CloudDrive state directory is not private to this user.")
    }
    return descriptor
}

private func checkedPrivateFile(_ descriptor: Int32) throws -> stat {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_nlink == 1 else { throw OwnershipError("CloudDrive state file has unsafe ownership or permissions.") }
    return info
}

/// All state operations are relative to a held, no-follow directory descriptor.
final class WorkerRecordStore {
    private let directory: Int32
    private let filename = "worker.json"
    init(directory: URL) throws { self.directory = try privateDirectory(directory) }
    deinit { close(directory) }

    func load() throws -> WorkerRecord? {
        let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw OwnershipError("Cannot safely read stored worker state.") }
        defer { close(descriptor) }
        let info = try checkedPrivateFile(descriptor)
        guard info.st_size > 0, info.st_size <= 65536 else { throw OwnershipError("Stored worker state has an invalid size.") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        let byteCount = bytes.count
        while offset < byteCount {
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!.advanced(by: offset), byteCount - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw OwnershipError("Stored worker state changed during read.") }
            offset += count
        }
        do {
            let record = try JSONDecoder().decode(WorkerRecord.self, from: Data(bytes))
            try record.validateShape(); return record
        } catch { throw OwnershipError("Stored worker state is malformed or unsupported. Pending cache was preserved.") }
    }

    func save(_ record: WorkerRecord) throws {
        try record.validateShape()
        // Refuse to overwrite a symlink or other unsafe existing file.
        let existing = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if existing >= 0 { defer { close(existing) }; _ = try checkedPrivateFile(existing) }
        else if errno != ENOENT { throw OwnershipError("Cannot safely replace stored worker state.") }
        let data = try JSONEncoder().encode(record)
        let temp = ".worker-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OwnershipError("Cannot create private worker state.") }
        defer { close(descriptor); unlinkat(directory, temp, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw OwnershipError("Cannot persist worker state.") }
            offset += count
        }
        guard fsync(descriptor) == 0, renameat(directory, temp, directory, filename) == 0 else {
            throw OwnershipError("Cannot commit worker state.")
        }
        guard fsync(directory) == 0 else { throw OwnershipError("Cannot synchronize worker state directory.") }
    }

    func remove(expectedSessionID: UUID) throws {
        guard let record = try load() else { return }
        guard record.sessionID == expectedSessionID else { throw OwnershipError("Worker session changed; its state was preserved.") }
        guard unlinkat(directory, filename, 0) == 0, fsync(directory) == 0 else {
            throw OwnershipError("Cannot remove the completed worker record.")
        }
    }
}

/// Hold one instance for the full lifetime of the app controller, not just mount startup.
final class OwnerLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        let dir = try privateDirectory(directory); defer { close(dir) }
        let descriptor = openat(dir, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OwnershipError("Cannot open the CloudDrive ownership lock.") }
        do { _ = try checkedPrivateFile(descriptor) } catch { close(descriptor); throw error }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw OwnershipError("Another CloudDrive app owns this connection. Use its existing window.")
        }
        self.descriptor = descriptor
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// Written before spawning so an app crash between spawn and full record commit is recoverable.
struct LaunchIntent: Codable, Equatable {
    var version: Int = 1
    var sessionID: UUID
    var executableSHA256: String
    var destinationFingerprint: String
    var cachePath: String
    var mountPath: String
    var nfsPort: Int
    var controlPort: Int
    var controlToken: String
    var expectedRemote: String

    func record(process: ProcessIdentity) -> WorkerRecord {
        WorkerRecord(sessionID: sessionID, process: process, executableSHA256: executableSHA256,
            destinationFingerprint: destinationFingerprint, cachePath: cachePath, mountPath: mountPath,
            nfsPort: nfsPort, controlPort: controlPort, controlToken: controlToken, expectedRemote: expectedRemote)
    }

    func validateShape() throws {
        guard version == 1, executableSHA256.count == 64, executableSHA256.allSatisfy({ $0.isHexDigit }),
              !destinationFingerprint.isEmpty, !expectedRemote.isEmpty,
              cachePath.hasPrefix("/"), mountPath.hasPrefix("/"),
              (1024...65535).contains(nfsPort), (1024...65535).contains(controlPort),
              nfsPort != controlPort, controlToken.utf8.count >= 32 else {
            throw OwnershipError("Pending launch state is malformed. No new worker was started.")
        }
    }
}

extension WorkerRecordStore {
    func loadIntent() throws -> LaunchIntent? {
        guard let data = try readPrivateData(filename: "launch.json") else { return nil }
        do {
            let intent = try JSONDecoder().decode(LaunchIntent.self, from: data)
            try intent.validateShape(); return intent
        } catch { throw OwnershipError("Pending launch state is malformed. No new worker was started.") }
    }

    func saveIntent(_ intent: LaunchIntent) throws {
        try intent.validateShape()
        try savePrivateData(JSONEncoder().encode(intent), filename: "launch.json")
    }

    func removeIntent(expectedSessionID: UUID) throws {
        guard let intent = try loadIntent() else { return }
        guard intent.sessionID == expectedSessionID else { throw OwnershipError("Pending launch session changed; state was preserved.") }
        guard unlinkat(directory, "launch.json", 0) == 0, fsync(directory) == 0 else { throw OwnershipError("Cannot retire pending launch state.") }
    }

    private func readPrivateData(filename: String) throws -> Data? {
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw OwnershipError("Cannot safely read private worker state.") }
        defer { close(fd) }
        let info = try checkedPrivateFile(fd)
        guard info.st_size > 0, info.st_size <= 65536 else { throw OwnershipError("Private worker state has invalid size.") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)); let size = bytes.count
        var offset = 0
        while offset < size {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), size - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw OwnershipError("Private worker state changed during read.") }
            offset += n
        }
        return Data(bytes)
    }

    private func savePrivateData(_ data: Data, filename: String) throws {
        let existing = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if existing >= 0 { defer { close(existing) }; _ = try checkedPrivateFile(existing) }
        else if errno != ENOENT { throw OwnershipError("Cannot safely replace private worker state.") }
        let temporary = ".launch-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OwnershipError("Cannot create private worker state.") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw OwnershipError("Cannot persist private worker state.") }
            offset += n
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, filename) == 0, fsync(directory) == 0 else {
            throw OwnershipError("Cannot commit private worker state.")
        }
    }
}

/// Keep running workers outside replaceable app bundles. Old versions remain available
/// until their sessions end; staging never overwrites an existing executable.
enum WorkerExecutable {
    static func stage(_ source: URL, root: URL) throws -> URL {
        let digest = try WorkerRecord.digest(source)
        let directory = root.appendingPathComponent("Workers").appendingPathComponent(digest)
        for path in [root.appendingPathComponent("Workers"), directory] {
            if !FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let descriptor = try privateDirectory(path)
            close(descriptor)
        }
        let target = directory.appendingPathComponent("rclone")
        if !FileManager.default.fileExists(atPath: target.path) {
            let temporary = directory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temporary.path)
            guard try WorkerRecord.digest(temporary) == digest else { throw OwnershipError("Backend changed during staging. Retry the build.") }
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        var info = stat()
        guard lstat(target.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o777 == 0o500,
              try WorkerRecord.digest(target) == digest else {
            throw OwnershipError("Stored worker executable failed validation. It was not replaced.")
        }
        return target
    }
}
