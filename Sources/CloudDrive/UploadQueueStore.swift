import Foundation
import SQLite3
import Darwin

/// Owned by DirectUploadEngine's actor. Only metadata is written here; never file payloads.
final class UploadQueueStore {
    let directory: URL
    private var db: OpaquePointer?
    private let lock: OwnerLock
    private var directoryIdentity: (dev_t, ino_t)?
    private var databaseIdentity: (dev_t, ino_t)?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL, createParentDirectories: Bool = true) throws {
        self.directory = directory
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: createParentDirectories, attributes: [.posixPermissions: 0o700])
        }
        self.lock = try OwnerLock(directory: directory)
        for name in ["uploads.sqlite", "uploads.sqlite-journal", "uploads.sqlite-wal", "uploads.sqlite-shm"] {
            let path = directory.appendingPathComponent(name).path
            var s = stat()
            if lstat(path, &s) == 0 {
                guard s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1 else {
                    throw DirectUploadFailure.message("Upload records must be private regular files owned by this user.")
                }
                guard chmod(path, 0o600) == 0 else { throw DirectUploadFailure.message("Cannot protect upload records.") }
            }
        }
        let path = directory.appendingPathComponent("uploads.sqlite").path
        // Pre-create with restrictive permissions before SQLite opens it.
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.storageError }
        close(descriptor)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw Self.storageError
        }
        do {
            var dirInfo = stat(), dbInfo = stat()
            guard lstat(directory.path, &dirInfo) == 0, lstat(path, &dbInfo) == 0 else { throw Self.storageError }
            directoryIdentity = (dirInfo.st_dev, dirInfo.st_ino); databaseIdentity = (dbInfo.st_dev, dbInfo.st_ino)
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA max_page_count=16384") // 64 MiB at a 4 KiB page size.
            try execute("CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, data BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS parts(job TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE, number INTEGER NOT NULL, etag TEXT NOT NULL, md5 TEXT NOT NULL, size INTEGER NOT NULL, PRIMARY KEY(job,number))")
            try execute("CREATE TABLE IF NOT EXISTS catalog_outbox(id TEXT PRIMARY KEY, destination TEXT NOT NULL, key BLOB NOT NULL, pending INTEGER NOT NULL DEFAULT 1)")
            let check = try statement("PRAGMA quick_check")
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, string(check, 0) == "ok" else { throw Self.storageError }
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }
    private static var storageError: DirectUploadFailure {
        .message("Upload records cannot be read or saved. Choose a writable records folder (it may be on an external drive), or recover the existing folder. No file payload is stored there.")
    }

    func load() throws -> [DirectUploadJob] {
        try assertAvailable()
        let query = try statement("SELECT data FROM jobs ORDER BY rowid")
        defer { sqlite3_finalize(query) }
        var jobs: [DirectUploadJob] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, jobs.count < 10_000,
                  sqlite3_column_bytes(query, 0) <= 262_144, let bytes = sqlite3_column_blob(query, 0) else { throw Self.storageError }
            var job = try JSONDecoder().decode(DirectUploadJob.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
            let parts = try statement("SELECT number,etag,md5,size FROM parts WHERE job=? ORDER BY number")
            defer { sqlite3_finalize(parts) }
            bind(job.id.uuidString, to: parts, at: 1)
            while true {
                let result = sqlite3_step(parts)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, job.parts.count < 10_000 else { throw Self.storageError }
                job.parts.append(ConfirmedUploadPart(number: Int(sqlite3_column_int64(parts, 0)), etag: string(parts, 1), md5: string(parts, 2), size: sqlite3_column_int64(parts, 3)))
            }
            try job.validate(); jobs.append(job)
        }
        return jobs
    }

    func insert(_ jobs: [DirectUploadJob]) throws {
        try transaction {
            let count = try statement("SELECT count(*) FROM jobs")
            defer { sqlite3_finalize(count) }
            guard sqlite3_step(count) == SQLITE_ROW, Int(sqlite3_column_int64(count, 0)) + jobs.count <= 10_000 else {
                throw DirectUploadFailure.message("The queue limit is 10,000 files. Clear completed history or use smaller batches.")
            }
            for job in jobs { try write(job, insert: true) }
        }
    }

    func save(_ job: DirectUploadJob) throws { try transaction { try write(job, insert: false) } }

    func savePart(_ part: ConfirmedUploadPart, job: DirectUploadJob) throws {
        try transaction {
            try write(job, insert: false)
            let s = try statement("INSERT OR REPLACE INTO parts(job,number,etag,md5,size) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(s) }
            bind(job.id.uuidString, to: s, at: 1); sqlite3_bind_int(s, 2, Int32(part.number))
            bind(part.etag, to: s, at: 3); bind(part.md5, to: s, at: 4); sqlite3_bind_int64(s, 5, part.size)
            guard sqlite3_step(s) == SQLITE_DONE else { throw Self.storageError }
        }
    }

    func reconcileParts(_ job: DirectUploadJob) throws {
        try transaction {
            let s = try statement("DELETE FROM parts WHERE job=?")
            defer { sqlite3_finalize(s) }
            bind(job.id.uuidString, to: s, at: 1)
            guard sqlite3_step(s) == SQLITE_DONE else { throw Self.storageError }
            // At most 10,000 small records, only on recovery, never per progress sample.
            for part in job.parts {
                let p = try statement("INSERT INTO parts VALUES(?,?,?,?,?)")
                defer { sqlite3_finalize(p) }
                bind(job.id.uuidString, to: p, at: 1); sqlite3_bind_int(p, 2, Int32(part.number))
                bind(part.etag, to: p, at: 3); bind(part.md5, to: p, at: 4); sqlite3_bind_int64(p, 5, part.size)
                guard sqlite3_step(p) == SQLITE_DONE else { throw Self.storageError }
            }
            try write(job, insert: false)
        }
    }

    func removeFinished(id: UUID? = nil) throws {
        for job in try load() where job.terminal && (id == nil || job.id == id) {
            try transaction {
                let s = try statement("DELETE FROM jobs WHERE id=?")
                defer { sqlite3_finalize(s) }
                bind(job.id.uuidString, to: s, at: 1)
                guard sqlite3_step(s) == SQLITE_DONE else { throw Self.storageError }
                try execute("DELETE FROM catalog_outbox WHERE pending=0 AND id NOT IN (SELECT id FROM jobs)")
            }
        }
    }

    func backfillCatalogHints(_ jobs: [DirectUploadJob]) throws {
        try transaction { for job in jobs { try saveCatalogHint(job) } }
    }
    func pendingCatalogHints(destination: String) throws -> [UploadCatalogHint] {
        try assertAvailable()
        let q = try statement("SELECT id,destination,key FROM catalog_outbox WHERE pending=1 AND destination=? ORDER BY rowid LIMIT 100")
        defer { sqlite3_finalize(q) }; bind(destination,to:q,at:1)
        var hints: [UploadCatalogHint] = []
        while true {
            let status = sqlite3_step(q)
            if status == SQLITE_DONE { return hints }
            guard status == SQLITE_ROW, let raw = sqlite3_column_blob(q,2), sqlite3_column_bytes(q,2) <= 1024 else { throw Self.storageError }
            let key = String(decoding:Data(bytes:raw,count:Int(sqlite3_column_bytes(q,2))),as:UTF8.self)
            hints.append(UploadCatalogHint(id:string(q,0),destination:string(q,1),key:key))
        }
    }
    func acknowledgeCatalogHints(_ hints: [UploadCatalogHint]) throws {
        guard hints.count <= 100 else { throw Self.storageError }
        try transaction {
            for hint in hints {
                let q = try statement("UPDATE catalog_outbox SET pending=0 WHERE id=? AND destination=? AND key=?")
                defer { sqlite3_finalize(q) }; bind(hint.id,to:q,at:1); bind(hint.destination,to:q,at:2)
                let bytes = Data(hint.key.utf8)
                _ = bytes.withUnsafeBytes { sqlite3_bind_blob(q,3,$0.baseAddress,Int32(bytes.count),transient) }; guard sqlite3_step(q) == SQLITE_DONE else { throw Self.storageError }
            }
            try execute("DELETE FROM catalog_outbox WHERE pending=0 AND id NOT IN (SELECT id FROM jobs)")
        }
    }
    private func saveCatalogHint(_ job: DirectUploadJob) throws {
        guard job.status == .uploaded, job.verifiedAt != nil else { return }
        let q = try statement("INSERT OR IGNORE INTO catalog_outbox(id,destination,key) VALUES(?,?,?)")
        defer { sqlite3_finalize(q) }; bind(job.id.uuidString,to:q,at:1); bind(job.destination,to:q,at:2)
        let bytes = Data(job.key.utf8)
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(q,3,$0.baseAddress,Int32(bytes.count),transient) }
        guard sqlite3_step(q) == SQLITE_DONE else { throw Self.storageError }
    }

    private func write(_ job: DirectUploadJob, insert: Bool) throws {
        try job.validate()
        var metadata = job; metadata.parts = []
        let data = try JSONEncoder().encode(metadata)
        guard data.count <= 262_144 else { throw Self.storageError }
        let s = try statement(insert ? "INSERT INTO jobs(id,data) VALUES(?,?)" : "UPDATE jobs SET data=?2 WHERE id=?1")
        defer { sqlite3_finalize(s) }
        bind(job.id.uuidString, to: s, at: 1)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(s) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw Self.storageError }
        try saveCatalogHint(job)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try assertAvailable()
        try execute("BEGIN IMMEDIATE")
        do { try body(); try assertAvailable(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func assertAvailable() throws {
        var dir = stat(), database = stat()
        guard let expectedDir = directoryIdentity, let expectedDB = databaseIdentity,
              lstat(directory.path, &dir) == 0,
              dir.st_mode & S_IFMT == S_IFDIR, dir.st_uid == getuid(), dir.st_mode & 0o077 == 0,
              dir.st_dev == expectedDir.0, dir.st_ino == expectedDir.1,
              lstat(directory.appendingPathComponent("uploads.sqlite").path, &database) == 0,
              database.st_mode & S_IFMT == S_IFREG, database.st_nlink == 1, database.st_uid == getuid(),
              database.st_mode & 0o077 == 0, database.st_dev == expectedDB.0, database.st_ino == expectedDB.1 else {
            throw Self.storageError
        }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.storageError }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw Self.storageError }
        return s
    }
    private func bind(_ value: String, to s: OpaquePointer, at index: Int32) { sqlite3_bind_text(s, index, value, -1, transient) }
    private func string(_ s: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(s, index).map { String(cString: $0) } ?? ""
    }
}
