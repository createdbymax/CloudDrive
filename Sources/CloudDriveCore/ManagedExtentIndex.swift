import Foundation
import SQLite3
import Darwin

/// Immutable paths share untouched address ranges between Finder write generations.
/// Branches span 32 subranges. Leaves cover 4 MiB. The published snapshot contains
/// only the root row ID; all rows for a new root commit before its manifest.
final class ManagedExtentIndex {
    static let leafBytes: Int64 = 4 * 1024 * 1024
    static let limit: Int64 = leafBytes << 25
    private struct Node: Codable {
        var branches: [Int: Int64]?
        var extents: [ContentExtent]?
    }
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    init(_ directory: URL) throws {
        let path = directory.resolvingSymlinksInPath().appendingPathComponent("extent-index.sqlite")
        let fd = open(path.path, O_RDWR | O_NOFOLLOW | O_CREAT, 0o600)
        guard fd >= 0 else { throw StorageFailure.integrity }
        Darwin.close(fd); _ = try CoreFileIO.regularSize(path)
        for suffix in ["-wal", "-shm", "-journal"] {
            let candidate = URL(fileURLWithPath: path.path + suffix)
            var info = stat()
            if lstat(candidate.path, &info) == 0 { _ = try CoreFileIO.regularSize(candidate) }
            else if errno != ENOENT { throw StorageFailure.integrity }
        }
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            close(); throw StorageFailure.integrity
        }
        do {
            try sql("PRAGMA trusted_schema=OFF; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON; CREATE TABLE IF NOT EXISTS pages(id INTEGER PRIMARY KEY AUTOINCREMENT, body BLOB NOT NULL, sha TEXT NOT NULL)")
        } catch { close(); throw error }
    }
    /// The content owner must close SQLite before releasing its ownership lock.
    /// Otherwise a replacement owner can race this connection's WAL shutdown.
    func close() {
        guard let db else { return }
        sqlite3_close_v2(db); self.db = nil
    }
    deinit { close() }
    private func sql(_ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw StorageFailure.integrity }
    }
    private func node(_ id: Int64) throws -> Node {
        var q: OpaquePointer?
        guard id > 0, sqlite3_prepare_v2(db, "SELECT body, sha FROM pages WHERE id=?", -1, &q, nil) == SQLITE_OK else { throw StorageFailure.integrity }
        defer { sqlite3_finalize(q) }
        sqlite3_bind_int64(q, 1, id)
        guard sqlite3_step(q) == SQLITE_ROW, let raw = sqlite3_column_blob(q, 0), let expected = sqlite3_column_text(q, 1) else { throw StorageFailure.integrity }
        let length = Int(sqlite3_column_bytes(q, 0))
        guard (1...16_777_216).contains(length) else { throw StorageFailure.integrity }
        let data = Data(bytes: raw, count: length)
        guard CoreFileIO.hash(data) == String(cString: expected) else { throw StorageFailure.integrity }
        let page = try JSONDecoder().decode(Node.self, from: data)
        if let branches = page.branches {
            guard page.extents == nil, branches.allSatisfy({ (0..<32).contains($0.key) && $0.value > 0 && $0.value < id }) else { throw StorageFailure.integrity }
        } else { guard page.extents != nil else { throw StorageFailure.integrity } }
        return page
    }
    private func save(_ value: Node) throws -> Int64 {
        let data = try encoder.encode(value)
        guard data.count <= 16_777_216 else { throw StorageFailure.localStorageFull }
        var q: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO pages(body,sha) VALUES(?,?)", -1, &q, nil) == SQLITE_OK else { throw StorageFailure.integrity }
        defer { sqlite3_finalize(q) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(q, 1, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_text(q, 2, CoreFileIO.hash(data), -1, transient)
        guard sqlite3_step(q) == SQLITE_DONE else { throw StorageFailure.localStorageFull }
        return sqlite3_last_insert_rowid(db)
    }
    /// Promote a legacy flat manifest in a single transaction, writing each page once.
    func build(extents: [ContentExtent]) throws -> Int64? {
        guard !extents.isEmpty else { return nil }
        try sql("BEGIN IMMEDIATE")
        do {
            var leaves: [Int64: Int64] = [:]
            var bucket: Int64 = -1
            var values: [ContentExtent] = []
            var previousEnd: Int64 = 0
            for old in extents.sorted(by: { $0.offset < $1.offset }) {
                guard old.offset >= previousEnd, old.length > 0, old.length <= old.storedLength,
                      old.storedLength <= 8 * 1024 * 1024, (old.fileOffset ?? 0) >= 0,
                      (old.fileOffset ?? 0) <= old.storedLength - old.length,
                      old.offset <= Self.limit - old.length else { throw StorageFailure.integrity }
                previousEnd = old.offset + old.length
                var start = old.offset
                while start < previousEnd {
                    let slot = start / Self.leafBytes
                    if slot != bucket {
                        if !values.isEmpty { leaves[bucket] = try save(Node(extents: values)) }
                        bucket = slot
                        values.removeAll(keepingCapacity: true)
                    }
                    var part = old
                    part.offset = start
                    part.fileOffset = (old.fileOffset ?? 0) + (start - old.offset)
                    part.length = min(previousEnd, (slot + 1) * Self.leafBytes) - start
                    values.append(part)
                    start += part.length
                }
            }
            leaves[bucket] = try save(Node(extents: values))
            for _ in 0..<5 {
                var parents: [Int64: [Int: Int64]] = [:]
                for (slot, child) in leaves { parents[slot / 32, default: [:]][Int(slot % 32)] = child }
                leaves = try parents.mapValues { try save(Node(branches: $0)) }
            }
            guard leaves.count == 1, let root = leaves[0] else { throw StorageFailure.integrity }
            try sql("COMMIT")
            return root
        } catch { try? sql("ROLLBACK"); throw error }
    }
    func replace(root: Int64?, folding tail: [ContentExtent] = [], range: Range<Int64>, extent: ContentExtent?) throws -> Int64? {
        guard range.lowerBound >= 0, range.upperBound <= Self.limit else { throw StorageFailure.invalidRange }
        try sql("BEGIN IMMEDIATE")
        do {
            var prefix = root
            for part in tail {
                prefix = try rewrite(prefix, start: 0, span: Self.limit,
                    range: part.offset..<(part.offset + part.length), extent: part)
            }
            let result = try rewrite(prefix, start: 0, span: Self.limit, range: range, extent: extent)
            try sql("COMMIT")
            return result
        } catch { try? sql("ROLLBACK"); throw error }
    }
    private func rewrite(_ root: Int64?, start: Int64, span: Int64, range: Range<Int64>, extent: ContentExtent?) throws -> Int64? {
        guard range.lowerBound < start + span && start < range.upperBound else { return root }
        if extent == nil && (root == nil || (range.lowerBound <= start && range.upperBound >= start + span)) { return nil }
        let old = try root.map(node)
        if span == Self.leafBytes {
            guard old?.branches == nil else { throw StorageFailure.integrity }
            var values = try ContentStore.extentsAfterReplacing(old?.extents ?? [], range: range)
            if var part = extent {
                let lower = max(start, range.lowerBound), upper = min(start + span, range.upperBound)
                part.fileOffset = (part.fileOffset ?? 0) + lower - part.offset
                part.offset = lower; part.length = upper - lower
                values.append(part)
            }
            return values.isEmpty ? nil : try save(Node(extents: values))
        }
        guard old?.extents == nil else { throw StorageFailure.integrity }
        var children = old?.branches ?? [:]
        let childSpan = span / 32
        let first = Int((max(start, range.lowerBound) - start) / childSpan)
        let last = Int((min(start + span, range.upperBound) - 1 - start) / childSpan)
        for slot in first...last {
            children[slot] = try rewrite(children[slot], start: start + Int64(slot) * childSpan, span: childSpan, range: range, extent: extent)
        }
        return children.isEmpty ? nil : try save(Node(branches: children))
    }
    func read(root: Int64, range: Range<Int64>) throws -> [ContentExtent] {
        var found: [ContentExtent] = []
        func visit(_ id: Int64, start: Int64, span: Int64) throws {
            let page = try node(id)
            if span == Self.leafBytes {
                guard let extents = page.extents else { throw StorageFailure.integrity }
                found += extents.filter { $0.offset < range.upperBound && $0.offset + $0.length > range.lowerBound }
                return
            }
            guard let children = page.branches else { throw StorageFailure.integrity }
            let childSpan = span / 32
            for (slot, child) in children {
                let offset = start + Int64(slot) * childSpan
                if offset < range.upperBound, offset + childSpan > range.lowerBound { try visit(child, start: offset, span: childSpan) }
            }
        }
        if !range.isEmpty { try visit(root, start: 0, span: Self.limit) }
        return found
    }
    /// Trace each shared page once, even when hundreds of old generations coexist.
    func reachable(_ roots: Set<Int64>, visit: (([ContentExtent]) -> Void)? = nil) throws -> (pages: Set<Int64>, extents: Set<UUID>) {
        var visited = Set<Int64>(), files = Set<UUID>(), pending = Array(roots)
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            let page = try node(id)
            if let children = page.branches { pending.append(contentsOf: children.values) }
            if let extents = page.extents { files.formUnion(extents.map(\.fileID)); visit?(extents) }
        }
        return (visited, files)
    }
    func prune(keeping roots: Set<Int64>) throws {
        // Keep free SQLite pages for reuse. A later generation can grow the same file.
        let pages = try reachable(roots).pages
        try sql("BEGIN IMMEDIATE")
        do {
            try sql("CREATE TEMP TABLE IF NOT EXISTS keep(id INTEGER PRIMARY KEY); DELETE FROM keep")
            var q: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO keep VALUES(?)", -1, &q, nil) == SQLITE_OK else { throw StorageFailure.integrity }
            defer { sqlite3_finalize(q) }
            for id in pages { sqlite3_reset(q); sqlite3_bind_int64(q, 1, id); guard sqlite3_step(q) == SQLITE_DONE else { throw StorageFailure.integrity } }
            try sql("DELETE FROM pages WHERE id NOT IN (SELECT id FROM keep); COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }
}
