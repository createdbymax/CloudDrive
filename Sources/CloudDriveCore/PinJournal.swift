import Foundation
import SQLite3
import Darwin

public struct PinProgress: Codable, Equatable, Sendable {
    public var nodeID: NodeID
    public var recursive: Bool
    public var generation: Int64
    public var size: Int64
    public var completedBytes: Int64
    public var state: String
    public var error: String?
}

/// Essential pin intent is independent of the disposable clean-chunk index. Updates
/// touch one SQLite row instead of rewriting every requested pin for each chunk.
final class PinJournal {
    private var db: OpaquePointer?
    let createdFresh: Bool
    private let url: URL
    private let identity: CoreDirectoryIdentity
    private var device: dev_t = 0
    private var inode: ino_t = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        let canonical = directory.resolvingSymlinksInPath()
        url = canonical.appendingPathComponent("pins.sqlite")
        identity = try CoreDirectoryIdentity(canonical)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageFailure.integrity }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { close(descriptor); throw StorageFailure.integrity }
        createdFresh = info.st_size == 0
        device = info.st_dev; inode = info.st_ino; close(descriptor)
        // Match NamespaceDatabase: pin the private regular file with O_NOFOLLOW,
        // then verify its device/inode again before any SQLite statement. The
        // system SQLite NOFOLLOW flag rejects legitimate macOS temp directories.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; db = nil; throw StorageFailure.integrity }
        do {
            try validate()
            try exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA busy_timeout=1000;")
            let version = try statement("PRAGMA user_version"); defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw StorageFailure.integrity }
            let schema = sqlite3_column_int(version, 0); guard schema == 0 || schema == 1 else { throw StorageFailure.integrity }
            try exec("CREATE TABLE IF NOT EXISTS pin_requests(node TEXT PRIMARY KEY,recursive INTEGER NOT NULL,generation INTEGER NOT NULL,size INTEGER NOT NULL,completed INTEGER NOT NULL,state TEXT NOT NULL,error TEXT); PRAGMA user_version=1;")
            try CoreFileIO.syncDirectory(directory)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    func validate() throws {
        try identity.validate(); var info = stat()
        guard db != nil, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_dev == device, info.st_ino == inode else { throw StorageFailure.integrity }
    }
    func all() throws -> [PinProgress] {
        try validate(); let q = try statement("SELECT node,recursive,generation,size,completed,state,error FROM pin_requests ORDER BY node")
        defer { sqlite3_finalize(q) }; var result = [PinProgress]()
        while true {
            let code = sqlite3_step(q); if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, result.count < 1_000_000, let id = UUID(uuidString: text(q,0)) else { throw StorageFailure.integrity }
            let value = PinProgress(nodeID: id, recursive: sqlite3_column_int(q,1) != 0, generation: sqlite3_column_int64(q,2), size: sqlite3_column_int64(q,3), completedBytes: sqlite3_column_int64(q,4), state: text(q,5), error: sqlite3_column_type(q,6) == SQLITE_NULL ? nil : text(q,6))
            guard value.generation >= 0, value.size >= 0, value.completedBytes >= 0, value.completedBytes <= value.size,
                  ["pending","working","complete","attention"].contains(value.state) else { throw StorageFailure.integrity }
            result.append(value)
        }
        return result
    }
    func put(_ value: PinProgress) throws {
        try validate()
        guard value.generation >= 0, value.size >= 0, value.completedBytes >= 0, value.completedBytes <= value.size, ["pending","working","complete","attention"].contains(value.state),
              (value.error?.utf8.count ?? 0) <= 1024 else { throw StorageFailure.integrity }
        let q = try statement("INSERT INTO pin_requests(node,recursive,generation,size,completed,state,error) VALUES(?,?,?,?,?,?,?) ON CONFLICT(node) DO UPDATE SET recursive=excluded.recursive,generation=excluded.generation,size=excluded.size,completed=excluded.completed,state=excluded.state,error=excluded.error")
        defer { sqlite3_finalize(q) }
        bind(value.nodeID.uuidString,q,1); sqlite3_bind_int(q,2,value.recursive ? 1:0); sqlite3_bind_int64(q,3,value.generation); sqlite3_bind_int64(q,4,value.size); sqlite3_bind_int64(q,5,value.completedBytes); bind(value.state,q,6)
        if let error = value.error { bind(error,q,7) } else { sqlite3_bind_null(q,7) }
        guard sqlite3_step(q) == SQLITE_DONE else { throw StorageFailure.integrity }
    }
    func remove(_ id: UUID) throws {
        try validate(); let q = try statement("DELETE FROM pin_requests WHERE node=?"); defer { sqlite3_finalize(q) }; bind(id.uuidString,q,1)
        guard sqlite3_step(q) == SQLITE_DONE else { throw StorageFailure.integrity }
    }
    private func bind(_ value: String, _ statement: OpaquePointer?, _ index: Int32) { _ = value.withCString { sqlite3_bind_text(statement,index,$0,-1,transient) } }
    private func text(_ q: OpaquePointer?, _ index: Int32) -> String { sqlite3_column_text(q,index).map { String(cString:$0) } ?? "" }
    private func statement(_ sql: String) throws -> OpaquePointer? {
        var q: OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&q,nil) == SQLITE_OK else { throw StorageFailure.integrity }; return q
    }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw StorageFailure.integrity } }
}
