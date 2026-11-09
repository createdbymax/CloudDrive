import Foundation
import SQLite3

extension NamespaceStore {
    /// A bounded derived filename index shares each namespace transaction. Folder
    /// descendants keep their IDs and terms; displayed paths resolve current ancestry.
    func updateNameProjection(_ node: NamespaceNode) throws {
        let lookup = try database.query("SELECT rowid,name FROM namespace_names WHERE node=?")
        database.bind(node.id.uuidString, lookup, 1)
        let status = sqlite3_step(lookup)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { sqlite3_finalize(lookup); throw NamespaceFailure.storage }
        let row = status == SQLITE_ROW ? sqlite3_column_int64(lookup, 0) : nil
        let old = status == SQLITE_ROW ? database.text(lookup, 1) : nil
        sqlite3_finalize(lookup)
        let visible = node.parentID != nil && node.deletedRevision == nil
        if let row, let old {
            if visible && old == node.name { return }
            let remove = try database.query("INSERT INTO namespace_terms(namespace_terms,rowid,name) VALUES('delete',?,?)")
            database.bind(row, remove, 1); database.bind(old, remove, 2)
            defer { sqlite3_finalize(remove) }; try database.done(remove)
            let clear = try database.query("DELETE FROM namespace_names WHERE node=?")
            database.bind(node.id.uuidString, clear, 1); defer { sqlite3_finalize(clear) }; try database.done(clear)
        }
        guard visible else { return }
        let insert = try database.query("INSERT INTO namespace_names(node,name) VALUES(?,?)")
        database.bind(node.id.uuidString, insert, 1); database.bind(node.name, insert, 2)
        defer { sqlite3_finalize(insert) }; try database.done(insert)
        let rowID = try database.query("SELECT rowid FROM namespace_names WHERE node=?")
        database.bind(node.id.uuidString, rowID, 1); defer { sqlite3_finalize(rowID) }
        guard sqlite3_step(rowID) == SQLITE_ROW else { throw NamespaceFailure.storage }
        let terms = try database.query("INSERT INTO namespace_terms(rowid,name) VALUES(?,?)")
        database.bind(sqlite3_column_int64(rowID, 0), terms, 1); database.bind(node.name, terms, 2)
        defer { sqlite3_finalize(terms) }; try database.done(terms)
    }
    public func searchNames(text: String, limit: Int = 100) throws -> [NamespaceNode] {
        try database.validate(); try ensureNotRestoring()
        guard text.count <= 256, text.utf8.count <= 1024, (1...1000).contains(limit) else { throw NamespaceFailure.limitExceeded }
        let tokens = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard tokens.count <= 12 else { throw NamespaceFailure.limitExceeded }
        let match = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        var found: [NamespaceNode] = [], offset = 0
        while found.count < limit {
            try Task.checkCancellation()
            guard offset <= 50_000 else { throw NamespaceFailure.limitExceeded }
            let sql = match.isEmpty
                ? "SELECT id FROM nodes WHERE parent IS NOT NULL AND deleted IS NULL ORDER BY comparison,id LIMIT 256 OFFSET ?"
                : "SELECT n.id FROM namespace_terms JOIN namespace_names s ON s.rowid=namespace_terms.rowid JOIN nodes n ON n.id=s.node WHERE namespace_terms MATCH ? AND n.deleted IS NULL ORDER BY bm25(namespace_terms),n.id LIMIT 256 OFFSET ?"
            let q = try database.query(sql)
            if match.isEmpty { database.bind(Int64(offset), q, 1) }
            else { database.bind(match, q, 1); database.bind(Int64(offset), q, 2) }
            var ids: [UUID] = []
            while true {
                let status = sqlite3_step(q); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)) else { sqlite3_finalize(q); throw NamespaceFailure.storage }
                ids.append(id)
            }
            sqlite3_finalize(q)
            for id in ids {
                let value = try rawNode(id)
                do { try assertVisible(value); if !(try isInTrash(value.id)) { found.append(value) } }
                catch NamespaceFailure.notFound { /* A deleted ancestor still retains descendant records. */ }
                if found.count == limit { return found }
            }
            offset += ids.count
            if ids.count < 256 { return found }
        }
        return found
    }
}
