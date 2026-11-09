import Foundation
import SQLite3

/// Durable operation state, not interpolated network progress. Sequence is the
/// stable ordering key; completed history never obscures unfinished operations.
public struct NamespaceActivityItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let nodeID: UUID
    public let sequence: Int64
    public let name: String
    public let path: String?
    public let kind: NamespaceOperationKind
    public let state: NamespaceOperationState
    public let size: Int64?
    public let attempts: Int
    public let failureCode: String?
    public let localOnly: Bool
}

extension NamespaceStore {
    public func activity(limit: Int = 200) throws -> [NamespaceActivityItem] {
        try database.validate(); try ensureNotRestoring()
        guard (1...500).contains(limit) else { throw NamespaceFailure.limitExceeded }
        let q = try database.query("SELECT id FROM operations ORDER BY CASE WHEN state='complete' THEN 1 ELSE 0 END, CASE WHEN state!='complete' THEN sequence END ASC, sequence DESC LIMIT ?")
        defer { sqlite3_finalize(q) }; database.bind(Int64(limit), q, 1)
        var result: [NamespaceActivityItem] = []
        while true {
            let status = sqlite3_step(q)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)),
                  let op = try operationUnchecked(id) else { throw NamespaceFailure.corrupt }
            let path = op.destinationPath ?? op.sourcePath
            result.append(.init(id: op.id, nodeID: op.nodeID, sequence: op.sequence,
                name: op.nodeSnapshot?.name ?? path.map { ($0 as NSString).lastPathComponent } ?? "File",
                path: path.map { String($0.prefix(4096)) }, kind: op.kind, state: op.state, size: op.nodeSnapshot?.size,
                attempts: op.attemptCount, failureCode: op.errorCode, localOnly: op.localOnly == true))
        }
        return result
    }
}
