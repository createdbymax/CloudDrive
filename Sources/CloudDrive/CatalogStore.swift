import Foundation
import SQLite3
import CryptoKit
import Darwin

/// All SQLite work is confined to this serial utility queue. DELETE journaling avoids
/// depending on OS-specific WAL fixes. Page transactions yield to interactive reads.
final class CatalogStore: @unchecked Sendable {
    let directory: URL
    let fingerprint: String
    let prefix: String
    private let queue = DispatchQueue(label: "CloudDrive.catalog", qos: .userInitiated)
    private var db: OpaquePointer?
    private var owner: OwnerLock?
    private var directoryIdentity: (dev_t, ino_t)?
    private var databaseIdentity: (dev_t, ino_t)?
    private let minimumFreeBytes: Int64
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL, fingerprint: String, prefix: String, minimumFreeBytes: Int64 = 268_435_456) {
        self.directory = directory; self.fingerprint = fingerprint; self.prefix = prefix; self.minimumFreeBytes = minimumFreeBytes
    }
    deinit { sqlite3_close(db) }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        let cancellation = CatalogQueryBudget(seconds: 30)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        try self.open()
                        try self.validateStorage()
                        continuation.resume(returning: try work())
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
    private func open() throws {
        if db != nil { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var dir = stat()
        guard lstat(directory.path, &dir) == 0, dir.st_mode & S_IFMT == S_IFDIR, dir.st_uid == getuid(),
              chmod(directory.path, 0o700) == 0 else { throw CatalogFailure.storage }
        owner = try OwnerLock(directory: directory)
        for name in ["catalog.sqlite", "catalog.sqlite-journal", "catalog.sqlite-wal", "catalog.sqlite-shm"] {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                      chmod(path, 0o600) == 0 else { owner = nil; throw CatalogFailure.storage }
            }
        }
        let path = directory.appendingPathComponent("catalog.sqlite").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { owner = nil; throw CatalogFailure.storage }
        close(fd)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; owner = nil; throw CatalogFailure.storage
        }
        do {
            sqlite3_busy_timeout(db, 250)
            try exec("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA max_page_count=1048576;")
            let version = try scalar("PRAGMA user_version")
            guard (0...3).contains(version) else { throw CatalogFailure.incompatible }
            if version == 0 {
                try transaction {
                    try exec("""
                    CREATE TABLE meta(fingerprint TEXT NOT NULL, prefix BLOB NOT NULL, completed REAL);
                    CREATE TABLE objects(id INTEGER PRIMARY KEY, key BLOB UNIQUE NOT NULL, name TEXT NOT NULL,
                      normalized TEXT NOT NULL, parent TEXT NOT NULL, extension TEXT NOT NULL,
                      size INTEGER NOT NULL CHECK(size>=0), modified REAL NOT NULL, etag TEXT NOT NULL,
                      seen INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
                    CREATE INDEX names ON objects(deleted,normalized,id);
                    CREATE INDEX extensions ON objects(deleted,extension,normalized,id);
                    CREATE VIRTUAL TABLE terms USING fts5(name,path,tokenize='unicode61',prefix='2 3 4');
                    CREATE TABLE scan(id INTEGER PRIMARY KEY, token TEXT, state TEXT NOT NULL);
                    CREATE TABLE tokens(token TEXT PRIMARY KEY);
                    PRAGMA user_version=1;
                    """)
                    let insert = try statement("INSERT INTO meta(fingerprint,prefix) VALUES(?,?)")
                    defer { sqlite3_finalize(insert) }; bind(fingerprint, insert, 1); blob(Data(prefix.utf8), insert, 2); try done(insert)
                }
            }
            if version < 2 {
                try transaction {
                    try exec("""
                    ALTER TABLE meta ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE meta ADD COLUMN reconcile INTEGER NOT NULL DEFAULT 1;
                    ALTER TABLE meta ADD COLUMN worker_session TEXT;
                    ALTER TABLE meta ADD COLUMN worker_sequence INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE objects ADD COLUMN local_revision INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE scan ADD COLUMN start_revision INTEGER NOT NULL DEFAULT 0;
                    CREATE TABLE pending_changes(key BLOB PRIMARY KEY, recursive INTEGER NOT NULL, revision INTEGER NOT NULL, attempt_order INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE change_versions(key BLOB PRIMARY KEY, revision INTEGER NOT NULL);
                    PRAGMA user_version=2;
                    """)
                }
            }
            if version < 3 {
                try transaction {
                    try exec("""
                    ALTER TABLE meta ADD COLUMN mass_signature TEXT;
                    ALTER TABLE meta ADD COLUMN mass_revision INTEGER;
                    ALTER TABLE meta ADD COLUMN mass_generation INTEGER;
                    PRAGMA user_version=3;
                    """)
                }
            }
            let meta = try statement("SELECT fingerprint,prefix FROM meta")
            defer { sqlite3_finalize(meta) }
            guard sqlite3_step(meta) == SQLITE_ROW, string(meta, 0) == fingerprint,
                  bytes(meta, 1) == Data(prefix.utf8) else { throw CatalogFailure.incompatible }
            var fileInfo = stat()
            guard lstat(path, &fileInfo) == 0 else { throw CatalogFailure.storage }
            directoryIdentity = (dir.st_dev, dir.st_ino); databaseIdentity = (fileInfo.st_dev, fileInfo.st_ino)
            let check = try statement("PRAGMA quick_check"); defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, string(check, 0) == "ok" else { throw CatalogFailure.storage }
        } catch { sqlite3_close(db); db = nil; owner = nil; throw error }
    }

    private func validateStorage() throws {
        var dir = stat(), file = stat()
        guard let a = directoryIdentity, let b = databaseIdentity,
              lstat(directory.path, &dir) == 0,
              lstat(directory.appendingPathComponent("catalog.sqlite").path, &file) == 0,
              dir.st_mode & S_IFMT == S_IFDIR, file.st_mode & S_IFMT == S_IFREG,
              dir.st_uid == getuid(), file.st_uid == getuid(), file.st_nlink == 1,
              dir.st_dev == a.0, dir.st_ino == a.1, file.st_dev == b.0, file.st_ino == b.1 else { throw CatalogFailure.storage }
    }
    private func checkSpace() throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < minimumFreeBytes { throw CatalogFailure.diskSpace }
    }

    func summary() async throws -> CatalogSummary {
        try await run {
            let q = try self.statement("SELECT (SELECT count(*) FROM objects WHERE deleted=0), completed, EXISTS(SELECT 1 FROM scan WHERE state!='complete') FROM meta")
            defer { sqlite3_finalize(q) }; guard sqlite3_step(q) == SQLITE_ROW else { throw CatalogFailure.storage }
            return CatalogSummary(count: Int(sqlite3_column_int64(q,0)),
                                  lastCompleted: sqlite3_column_type(q,1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(q,1)),
                                  hasPartialScan: sqlite3_column_int(q,2) == 1)
        }
    }
    func beginScan(fresh: Bool) async throws -> CatalogScan {
        try await run {
            if !fresh {
                let q = try self.statement("SELECT scan.id,scan.token FROM scan,meta WHERE state='scanning' AND scan.start_revision=meta.revision")
                defer { sqlite3_finalize(q) }
                if sqlite3_step(q) == SQLITE_ROW { return CatalogScan(id: sqlite3_column_int64(q,0), token: sqlite3_column_type(q,1) == SQLITE_NULL ? nil : self.string(q,1)) }
            }
            return try self.transaction {
                let next = try self.scalar("SELECT coalesce(max(id),0)+1 FROM scan")
                try self.exec("DELETE FROM scan; DELETE FROM tokens;")
                let q = try self.statement("INSERT INTO scan(id,state,start_revision) SELECT ?,'scanning',revision FROM meta")
                defer { sqlite3_finalize(q) }; sqlite3_bind_int64(q,1,next); try self.done(q)
                return CatalogScan(id: next, token: nil)
            }
        }
    }
    func commit(page: InventoryPage, scan: CatalogScan) async throws {
        try await run {
            try self.checkSpace()
            guard page.objects.count <= 1000 else { throw CatalogFailure.invalidInventory }
            for object in page.objects { try CatalogText.validate(object, prefix: self.prefix) }
            guard Set(page.objects.map(\.id)).count == page.objects.count else { throw CatalogFailure.invalidInventory }
            try self.transaction {
                try self.checkScanRevision(scan.id)
                let check = try self.statement("SELECT id,token,state FROM scan"); defer { sqlite3_finalize(check) }
                guard sqlite3_step(check) == SQLITE_ROW, sqlite3_column_int64(check,0) == scan.id,
                      self.string(check,2) == "scanning",
                      (sqlite3_column_type(check,1) == SQLITE_NULL ? nil : self.string(check,1)) == scan.token else { throw CatalogFailure.superseded }
                if let token = page.nextToken {
                    guard !token.isEmpty, token.utf8.count <= 16_384 else { throw CatalogFailure.invalidInventory }
                    let t = try self.statement("INSERT INTO tokens VALUES(?)"); defer { sqlite3_finalize(t) }
                    self.bind(token,t,1)
                    guard sqlite3_step(t) == SQLITE_DONE else { throw CatalogFailure.invalidInventory }
                }
                for object in page.objects { try self.upsert(object, scan: scan.id) }
                let q = try self.statement("UPDATE scan SET token=?,state=? WHERE id=?"); defer { sqlite3_finalize(q) }
                if let token = page.nextToken { self.bind(token,q,1) } else { sqlite3_bind_null(q,1) }
                self.bind(page.nextToken == nil ? "reconciling" : "scanning",q,2); sqlite3_bind_int64(q,3,scan.id); try self.done(q)
            }
        }
    }
    func missingCandidates(scanID: Int64, after: Int64 = 0) async throws -> [(Int64, String)] {
        try await run {
            let q = try self.statement("SELECT id,key FROM objects WHERE deleted=0 AND seen!=? AND id>? ORDER BY id LIMIT 100")
            defer { sqlite3_finalize(q) }; sqlite3_bind_int64(q,1,scanID); sqlite3_bind_int64(q,2,after)
            var result: [(Int64,String)] = []
            while try self.row(q) { result.append((sqlite3_column_int64(q,0), String(decoding: self.bytes(q,1), as: UTF8.self))) }
            return result
        }
    }
    func confirmMissing(id: Int64, scanID: Int64) async throws {
        try await run {
            try self.transaction {
                try self.checkScanRevision(scanID)
                let q = try self.statement("UPDATE objects SET deleted=1 WHERE id=? AND seen!=? AND EXISTS(SELECT 1 FROM scan WHERE id=? AND state='reconciling')")
                defer { sqlite3_finalize(q) }; sqlite3_bind_int64(q,1,id); sqlite3_bind_int64(q,2,scanID); sqlite3_bind_int64(q,3,scanID); try self.done(q)
                if sqlite3_changes(self.db) == 1 { try self.exec("DELETE FROM terms WHERE rowid=\(id)") }
            }
        }
    }
    func finish(scanID: Int64) async throws {
        try await run {
            try self.transaction {
                try self.checkScanRevision(scanID)
                let q = try self.statement("UPDATE scan SET state='complete' WHERE id=? AND state='reconciling'")
                defer { sqlite3_finalize(q) }; sqlite3_bind_int64(q,1,scanID); try self.done(q)
                guard sqlite3_changes(self.db) == 1 else { throw CatalogFailure.superseded }
                try self.exec("UPDATE meta SET completed=\(Date().timeIntervalSince1970),reconcile=0,mass_signature=NULL,mass_revision=NULL,mass_generation=NULL; DELETE FROM tokens;")
            }
        }
    }
    func search(_ query: CatalogQuery) async throws -> [CatalogObject] {
        let terms = try query.terms(), budget = CatalogQueryBudget(seconds: 0.15)
        return try await withTaskCancellationHandler(operation: {
            try await run {
                if budget.isCancelled { throw CancellationError() }
                budget.start()
                sqlite3_progress_handler(self.db, 500, { raw in
                    guard let raw else { return 1 }
                    return Unmanaged<CatalogQueryBudget>.fromOpaque(raw).takeUnretainedValue().shouldStop ? 1 : 0
                }, Unmanaged.passUnretained(budget).toOpaque())
                defer { sqlite3_progress_handler(self.db,0,nil,nil) }
                let ext = CatalogText.normalize(query.fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
                let expression = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
                // Filename hits precede path-only hits. Rowid order lets FTS stop at
                // the result limit instead of scoring every common-word match.
                let matches: [String?] = terms.isEmpty ? [nil] : ["name : (" + expression + ")", expression]
                var result: [CatalogObject] = [], found = Set<Data>()
                let wanted = query.limit + query.offset
                for match in matches {
                    let sql: String
                    if match == nil {
                        sql = "SELECT o.key,o.size,o.modified,o.etag FROM objects o WHERE o.deleted=0 AND (?='' OR o.extension=?) AND o.size>=? ORDER BY o.normalized,o.id LIMIT ?"
                    } else {
                        sql = "SELECT o.key,o.size,o.modified,o.etag FROM terms JOIN objects o ON o.id=terms.rowid WHERE terms MATCH ? AND o.deleted=0 AND (?='' OR o.extension=?) AND o.size>=? ORDER BY terms.rowid LIMIT ?"
                    }
                    let q = try self.statement(sql); defer { sqlite3_finalize(q) }
                    var i: Int32 = 1
                    if let match { self.bind(match,q,i); i += 1 }
                    self.bind(ext,q,i); self.bind(ext,q,i+1); sqlite3_bind_int64(q,i+2,query.minimumSize)
                    sqlite3_bind_int(q,i+3,Int32(wanted))
                    while true {
                        let status = sqlite3_step(q)
                        if status == SQLITE_DONE { break }
                        if status == SQLITE_INTERRUPT {
                            if budget.isCancelled { throw CancellationError() }
                            throw CatalogFailure.queryTimedOut
                        }
                        guard status == SQLITE_ROW else { throw CatalogFailure.storage }
                        let key = self.bytes(q,0)
                        if found.insert(key).inserted {
                            result.append(CatalogObject(key: String(decoding: key, as: UTF8.self), size: sqlite3_column_int64(q,1), modified: Date(timeIntervalSince1970: sqlite3_column_double(q,2)), etag: self.string(q,3)))
                        }
                    }
                    if result.count >= wanted { break }
                }
                return Array(result.dropFirst(query.offset).prefix(query.limit))
            }
        }, onCancel: { budget.cancel() })
    }
    private func checkScanRevision(_ id: Int64) throws {
        let q = try statement("SELECT 1 FROM scan,meta WHERE scan.id=? AND scan.start_revision=meta.revision")
        defer { sqlite3_finalize(q) }; sqlite3_bind_int64(q,1,id)
        guard try row(q) else { throw CatalogFailure.superseded }
    }
    private func checkReconcilingScan(_ id: Int64) throws {
        try checkScanRevision(id)
        let q = try statement("SELECT 1 FROM scan WHERE id=? AND state='reconciling'")
        defer { sqlite3_finalize(q) }; sqlite3_bind_int64(q,1,id)
        guard try row(q) else { throw CatalogFailure.superseded }
    }
    /// Requires the same absent key set in two complete generations at the same
    /// mutation revision. Hashing yields between pages so search can interleave.
    func largeMissingIsConfirmed(scanID: Int64) async throws -> Bool {
        var digest = SHA256(), after: Data?
        while true {
            try Task.checkCancellation()
            let cursor = after
            let keys: [Data] = try await run {
                try self.checkReconcilingScan(scanID)
                let q = try self.statement("SELECT key FROM objects WHERE deleted=0 AND seen!=?" + (cursor == nil ? "" : " AND key>?") + " ORDER BY key LIMIT 1000")
                defer { sqlite3_finalize(q) }; sqlite3_bind_int64(q,1,scanID)
                if let cursor { self.blob(cursor,q,2) }
                var keys: [Data] = []
                while try self.row(q) { keys.append(self.bytes(q,0)) }
                return keys
            }
            if keys.isEmpty { break }
            for key in keys { digest.update(data:key); digest.update(data:Data([0])) }
            after = keys.last
        }
        let signature = digest.finalize().map { String(format:"%02x",$0) }.joined()
        return try await run {
            try self.transaction {
                try self.checkReconcilingScan(scanID)
                let q = try self.statement("SELECT mass_signature,mass_revision,mass_generation,revision FROM meta")
                defer { sqlite3_finalize(q) }; guard try self.row(q) else { throw CatalogFailure.storage }
                let confirmed = self.string(q,0) == signature && sqlite3_column_type(q,1) != SQLITE_NULL && sqlite3_column_int64(q,1) == sqlite3_column_int64(q,3) && sqlite3_column_int64(q,2) != scanID
                if confirmed { return true }
                let update = try self.statement("UPDATE meta SET mass_signature=?,mass_revision=revision,mass_generation=?,reconcile=1")
                defer { sqlite3_finalize(update) }; self.bind(signature,update,1); sqlite3_bind_int64(update,2,scanID); try self.done(update)
                return false
            }
        }
    }
    func requireReconciliation() async throws {
        try await run { try self.exec("UPDATE meta SET revision=revision+1,reconcile=1") }
    }
    func needsReconciliation() async throws -> Bool {
        try await run { try self.scalar("SELECT reconcile OR completed IS NULL FROM meta") != 0 }
    }
    func workerCursor() async throws -> CatalogWorkerCursor {
        try await run {
            let q = try self.statement("SELECT worker_session,worker_sequence FROM meta"); defer { sqlite3_finalize(q) }
            guard try self.row(q) else { throw CatalogFailure.storage }
            return CatalogWorkerCursor(session:sqlite3_column_type(q,0) == SQLITE_NULL ? nil : self.string(q,0),sequence:sqlite3_column_int64(q,1))
        }
    }
    func recordWorkerChanges(_ page: WorkerMetadataChanges, after: Int64) async throws {
        try page.validate(after:after)
        try await run {
            try self.transaction {
                let q = try self.statement("SELECT worker_session,worker_sequence FROM meta"); defer { sqlite3_finalize(q) }
                guard try self.row(q) else { throw CatalogFailure.storage }
                let session = self.string(q,0), sequence = sqlite3_column_int64(q,1)
                if session == page.session {
                    if sequence == page.next && !page.gap { return } // Idempotent delivery after an acknowledgement loss.
                    guard sequence == after else { throw CatalogFailure.superseded }
                }
                if session != page.session || page.gap { try self.exec("UPDATE meta SET revision=revision+1,reconcile=1") }
                for event in page.events {
                    if event.path.isEmpty { try self.exec("UPDATE meta SET revision=revision+1,reconcile=1"); continue }
                    try self.enqueueKey(self.prefix + "/" + event.path,recursive:event.recursive)
                }
                let update = try self.statement("UPDATE meta SET worker_session=?,worker_sequence=?"); defer { sqlite3_finalize(update) }
                self.bind(page.session,update,1); sqlite3_bind_int64(update,2,page.next); try self.done(update)
            }
        }
    }
    func recordUploadHints(_ hints: [UploadCatalogHint]) async throws {
        guard hints.count <= 100, hints.allSatisfy({ $0.destination == fingerprint }) else { throw CatalogFailure.superseded }
        try await run { try self.transaction { for hint in hints { try self.enqueueKey(hint.key,recursive:false) } } }
    }
    private func enqueueKey(_ key: String, recursive: Bool) throws {
        guard key.utf8.starts(with:(prefix + "/").utf8), key.utf8.count <= 1024, !key.contains("\0"),
              !key.split(separator:"/",omittingEmptySubsequences:false).contains(where:{ $0 == "." || $0 == ".." }) else {
            // Oversized/unsupported hints require a complete remote inventory instead.
            try exec("UPDATE meta SET revision=revision+1,reconcile=1"); return
        }
        try exec("UPDATE meta SET revision=revision+1,reconcile=CASE WHEN EXISTS(SELECT 1 FROM scan WHERE state!='complete') THEN 1 ELSE reconcile END")
        let q = try statement("INSERT INTO pending_changes(key,recursive,revision) SELECT ?,?,revision FROM meta WHERE true ON CONFLICT(key) DO UPDATE SET recursive=max(pending_changes.recursive,excluded.recursive),revision=excluded.revision,attempt_order=0")
        defer { sqlite3_finalize(q) }; blob(Data(key.utf8),q,1); sqlite3_bind_int(q,2,recursive ? 1 : 0); try done(q)
    }
    func pendingChanges(limit: Int = 100) async throws -> [CatalogChange] {
        try await run {
            let q = try self.statement("SELECT key,recursive,revision FROM pending_changes ORDER BY attempt_order,revision LIMIT ?"); defer { sqlite3_finalize(q) }
            sqlite3_bind_int(q,1,Int32(max(1,min(100,limit))))
            var changes: [CatalogChange] = []
            while try self.row(q) { changes.append(CatalogChange(key:String(decoding:self.bytes(q,0),as:UTF8.self),recursive:sqlite3_column_int(q,1) != 0,revision:sqlite3_column_int64(q,2))) }
            return changes
        }
    }
    private func checkChange(_ change: CatalogChange) throws {
        let q = try statement("SELECT 1 FROM pending_changes WHERE key=? AND revision=?"); defer { sqlite3_finalize(q) }
        blob(Data(change.key.utf8),q,1); sqlite3_bind_int64(q,2,change.revision)
        guard try row(q) else { throw CatalogFailure.superseded }
    }
    func changedDescendants(change: CatalogChange, after: String?) async throws -> [String] {
        try await run {
            try self.checkChange(change)
            let lower = Data((change.key + "/").utf8)
            var upper = lower; upper[upper.count-1] += 1
            let q = try self.statement("SELECT key FROM objects WHERE deleted=0 AND key>=? AND key<? AND key>? AND local_revision<? ORDER BY key LIMIT 100")
            defer { sqlite3_finalize(q) }; self.blob(lower,q,1); self.blob(upper,q,2)
            self.blob(Data((after ?? change.key).utf8),q,3); sqlite3_bind_int64(q,4,change.revision)
            var keys: [String] = []
            while try self.row(q) { keys.append(String(decoding:self.bytes(q,0),as:UTF8.self)) }
            return keys
        }
    }
    func applyChangedObjects(_ objects: [CatalogObject], change: CatalogChange) async throws {
        guard objects.count <= 1000 else { throw CatalogFailure.invalidInventory }
        for object in objects {
            try CatalogText.validate(object,prefix:prefix)
            guard object.key.utf8.starts(with:(change.key + "/").utf8) else { throw CatalogFailure.invalidInventory }
        }
        try await run {
            try self.checkSpace()
            try self.transaction {
                try self.checkChange(change)
                for object in objects { try self.applyObservation(object,key:object.key,change:change) }
            }
        }
    }
    func applyChangedObject(_ object: CatalogObject?, key: String, change: CatalogChange) async throws {
        if let object { try CatalogText.validate(object,prefix:prefix); guard object.id == Data(key.utf8) else { throw CatalogFailure.invalidInventory } }
        guard Data(key.utf8) == Data(change.key.utf8) || (change.recursive && key.utf8.starts(with:(change.key + "/").utf8)) else { throw CatalogFailure.invalidInventory }
        try await run {
            try self.checkSpace()
            try self.transaction { try self.checkChange(change); try self.applyObservation(object,key:key,change:change) }
        }
    }
    private func applyObservation(_ object: CatalogObject?, key: String, change: CatalogChange) throws {
        let guardQuery = try statement("""
        SELECT EXISTS(SELECT 1 FROM change_versions WHERE key=?1 AND revision>?2) OR
        EXISTS(SELECT 1 FROM pending_changes WHERE revision>?2 AND
          (key=?1 OR (recursive=1 AND substr(?1,1,length(key)+1)=CAST(key||'/' AS BLOB))))
        """)
        defer { sqlite3_finalize(guardQuery) }; blob(Data(key.utf8),guardQuery,1); sqlite3_bind_int64(guardQuery,2,change.revision)
        guard try row(guardQuery) else { throw CatalogFailure.storage }
        if sqlite3_column_int(guardQuery,0) != 0 { return }
        let version = try statement("INSERT INTO change_versions(key,revision) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET revision=max(change_versions.revision,excluded.revision)")
        defer { sqlite3_finalize(version) }; blob(Data(key.utf8),version,1); sqlite3_bind_int64(version,2,change.revision); try done(version)
        if let object { try upsert(object,scan:-1) }
        let q = try statement("UPDATE objects SET deleted=?,local_revision=? WHERE key=? RETURNING id")
        defer { sqlite3_finalize(q) }; sqlite3_bind_int(q,1,object == nil ? 1 : 0); sqlite3_bind_int64(q,2,change.revision); blob(Data(key.utf8),q,3)
        if try row(q) {
            let id = sqlite3_column_int64(q,0)
            guard sqlite3_step(q) == SQLITE_DONE else { throw CatalogFailure.storage }
            if object == nil { try exec("DELETE FROM terms WHERE rowid=\(id)") }
        }
    }
    func deferChange(_ change: CatalogChange) async throws {
        try await run {
            let q = try self.statement("UPDATE pending_changes SET attempt_order=(SELECT coalesce(max(attempt_order),0)+1 FROM pending_changes) WHERE key=? AND revision=?")
            defer { sqlite3_finalize(q) }; self.blob(Data(change.key.utf8),q,1); sqlite3_bind_int64(q,2,change.revision); try self.done(q)
        }
    }
    func acknowledgeChange(_ change: CatalogChange) async throws {
        try await run {
            let q = try self.statement("DELETE FROM pending_changes WHERE key=? AND revision=?"); defer { sqlite3_finalize(q) }
            self.blob(Data(change.key.utf8),q,1); sqlite3_bind_int64(q,2,change.revision); try self.done(q)
        }
    }
    private func upsert(_ object: CatalogObject, scan: Int64) throws {
        let q = try statement("""
        INSERT INTO objects(key,name,normalized,parent,extension,size,modified,etag,seen) VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET name=excluded.name,normalized=excluded.normalized,parent=excluded.parent,
          extension=excluded.extension,size=excluded.size,modified=excluded.modified,etag=excluded.etag,seen=excluded.seen,deleted=0
        RETURNING id
        """)
        defer { sqlite3_finalize(q) }
        blob(object.id,q,1); bind(object.name,q,2); bind(CatalogText.normalize(object.name),q,3); bind(object.parent,q,4)
        bind(CatalogText.normalize(object.fileExtension),q,5); sqlite3_bind_int64(q,6,object.size); sqlite3_bind_double(q,7,object.modified.timeIntervalSince1970)
        bind(object.etag,q,8); sqlite3_bind_int64(q,9,scan)
        guard sqlite3_step(q) == SQLITE_ROW else { throw CatalogFailure.storage }
        let id = sqlite3_column_int64(q,0)
        guard sqlite3_step(q) == SQLITE_DONE else { throw CatalogFailure.storage }
        try exec("DELETE FROM terms WHERE rowid=\(id)")
        let f = try statement("INSERT INTO terms(rowid,name,path) VALUES(?,?,?)"); defer { sqlite3_finalize(f) }
        sqlite3_bind_int64(f,1,id); bind(CatalogText.normalize(object.name),f,2); bind(CatalogText.normalize(object.key),f,3); try done(f)
    }
    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let value = try work(); try exec("COMMIT"); return value }
        catch { try? exec("ROLLBACK"); throw error }
    }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw CatalogFailure.storage } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var q: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&q,nil) == SQLITE_OK, let q else { throw CatalogFailure.storage }; return q
    }
    private func row(_ q: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(q); if result == SQLITE_DONE { return false }
        guard result == SQLITE_ROW else { throw CatalogFailure.storage }; return true
    }
    private func done(_ q: OpaquePointer) throws { guard sqlite3_step(q) == SQLITE_DONE else { throw CatalogFailure.storage } }
    private func scalar(_ sql: String) throws -> Int64 {
        let q = try statement(sql); defer { sqlite3_finalize(q) }; guard try row(q) else { throw CatalogFailure.storage }; return sqlite3_column_int64(q,0)
    }
    private func bind(_ value: String, _ q: OpaquePointer, _ i: Int32) { sqlite3_bind_text(q,i,value,-1,transient) }
    private func blob(_ value: Data, _ q: OpaquePointer, _ i: Int32) { _ = value.withUnsafeBytes { sqlite3_bind_blob(q,i,$0.baseAddress,Int32(value.count),transient) } }
    private func string(_ q: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(q,i).map { String(cString:$0) } ?? "" }
    private func bytes(_ q: OpaquePointer, _ i: Int32) -> Data { sqlite3_column_blob(q,i).map { Data(bytes:$0,count:Int(sqlite3_column_bytes(q,i))) } ?? Data() }
}

private final class CatalogQueryBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadline = UInt64.max
    private let seconds: Double
    init(seconds: Double) { self.seconds = seconds }
    func start() { lock.lock(); deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000); lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || DispatchTime.now().uptimeNanoseconds > deadline }
}
