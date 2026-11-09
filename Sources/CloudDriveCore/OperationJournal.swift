import Foundation
import CryptoKit
import SQLite3

extension NamespaceStore {
    struct PendingOperationSummary {
        var count = 0
        var attention = 0
        var attentionErrors: [String?] = []
        var firstError: String?
    }
    /// Status polling must not deserialize the journal or truncate its count.
    func pendingOperationSummary() throws -> PendingOperationSummary {
        try database.validate()
        var result = PendingOperationSummary()
        // Frequent status polls share the writer's actor. Use the state index
        // for the count and only fetch full rows when an error is needed.
        let count = try database.query("SELECT COUNT(*) FROM operations WHERE state IN ('pending','running','attention')")
        defer { sqlite3_finalize(count) }
        guard sqlite3_step(count) == SQLITE_ROW else { throw NamespaceFailure.storage }
        result.count = Int(sqlite3_column_int64(count, 0))
        let q = try database.query("SELECT error,COUNT(*) FROM operations WHERE state='attention' GROUP BY error")
        defer { sqlite3_finalize(q) }
        while true {
            let step = sqlite3_step(q)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw NamespaceFailure.storage }
            result.attention += Int(sqlite3_column_int64(q, 1))
            result.attentionErrors.append(sqlite3_column_type(q, 0) == SQLITE_NULL ? nil : database.text(q, 0))
        }
        let first = try database.query("""
            SELECT error FROM operations WHERE sequence = (SELECT MIN(sequence) FROM (
                SELECT MIN(sequence) AS sequence FROM operations WHERE state='pending'
                UNION ALL SELECT MIN(sequence) FROM operations WHERE state='running'
                UNION ALL SELECT MIN(sequence) FROM operations WHERE state='attention'
            ))
            """)
        defer { sqlite3_finalize(first) }
        let step = sqlite3_step(first)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw NamespaceFailure.storage }
        if step == SQLITE_ROW, sqlite3_column_type(first, 0) != SQLITE_NULL { result.firstError = database.text(first, 0) }
        return result
    }
    /// Operations remain durable after completion so an authenticated request ID can
    /// reconcile a lost reply across process restart without repeating a mutation.
    public func operation(_ id: UUID) throws -> NamespaceOperation? { try database.validate(); return try operationUnchecked(id) }
    public func operations(limit: Int = 256, includeComplete: Bool = false) throws -> [NamespaceOperation] {
        try database.validate(); guard (1...10_000).contains(limit) else { throw NamespaceFailure.limitExceeded }
        let q = try database.query("SELECT id FROM operations \(includeComplete ? "" : "WHERE state!='complete'") ORDER BY sequence LIMIT ?")
        defer { sqlite3_finalize(q) }; database.bind(Int64(limit), q, 1)
        var result: [NamespaceOperation] = []
        while true {
            let status = sqlite3_step(q); if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)), let op = try operationUnchecked(id) else { throw NamespaceFailure.corrupt }
            result.append(op)
        }
        return result
    }
    /// Advisory look-ahead for immutable payload preparation. This leaves the
    /// journal and ordered publication frontier untouched.
    func managedPayloadCandidates(limit: Int) throws -> [NamespaceOperation] {
        let clock = ContinuousClock(); var mark = clock.now
        func lap(_ name: String) { EngineTrace.record("candidates." + name, clock.now - mark); mark = clock.now }
        try database.validate()
        guard (1...256).contains(limit) else { throw NamespaceFailure.limitExceeded }
        try ensureNotRestoring()
        guard try volumeUnchecked().mode == .managed else { return [] }
        lap("prelude")
        try database.sealOpenWrites()
        lap("seal")
        // Look just ahead of the ordered publisher. In a deep backlog, the
        // newest writes can be hours away from the next publication. Bound
        // the index walk even when the prefix is mostly metadata or old writes.
        let lookAhead = max(256, limit * 32)
        let query = try database.query("""
            SELECT candidate.id
            FROM operations AS candidate INDEXED BY pending_operations
            JOIN nodes AS node ON node.id = candidate.node
            JOIN content AS content ON content.node = node.id AND content.generation = node.content_generation
            WHERE candidate.state = 'pending'
              AND candidate.sequence <= COALESCE((
                  SELECT sequence FROM operations INDEXED BY pending_operations
                  WHERE state = 'pending' ORDER BY sequence LIMIT 1 OFFSET ?
              ), ?)
              AND candidate.kind = 'write' AND candidate.attempts = 0 AND candidate.error IS NULL
              AND node.kind = 'file' AND node.deleted IS NULL AND node.size > 0
              AND content.published = 0 AND content.size = node.size AND content.snapshot != ''
              AND json_extract(CAST(candidate.payload AS TEXT), '$.targetGeneration') = node.content_generation
              AND json_extract(CAST(candidate.payload AS TEXT), '$.stagedSnapshotID') = content.snapshot
              AND NOT EXISTS (
                  SELECT 1 FROM receipts
                  WHERE operation = candidate.id AND step != 'mutation-fingerprint'
              )
              AND NOT EXISTS (
                  SELECT 1 FROM operations AS successor
                  WHERE successor.sequence = candidate.sequence + 1
                    AND successor.kind = 'write' AND successor.node = candidate.node
              )
            ORDER BY candidate.sequence
            """)
        defer { sqlite3_finalize(query) }
        lap("prepare")
        database.bind(Int64(lookAhead - 1), query, 1)
        database.bind(Int64.max, query, 2)
        var result: [NamespaceOperation] = []
        defer { lap("rows") }
        while result.count < limit {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(query, 0)),
                  let operation = try operationUnchecked(id) else { throw NamespaceFailure.corrupt }
            guard operation.localOnly != true, let snapshot = operation.nodeSnapshot,
                  snapshot.id == operation.nodeID, snapshot.contentGeneration == operation.targetGeneration,
                  snapshot.kind == .file, snapshot.size > 0 else { continue }
            // Recursive remove tombstones a parent without rewriting descendants.
            // Keep those descendants out of speculative preparation as well.
            do { try assertVisible(rawNode(operation.nodeID)) }
            catch NamespaceFailure.notFound { continue }
            result.append(operation)
        }
        return result
    }
    public func setOperationState(_ id: UUID, state: NamespaceOperationState, errorCode: String? = nil) throws {
        try database.transaction {
            guard let op = try operationUnchecked(id) else { throw NamespaceFailure.operationNotFound }
            guard op.state != .complete, state != .complete, (errorCode?.utf8.count ?? 0) <= 1024 else { throw NamespaceFailure.invalidTransition }
            if state == .running { try assertDependenciesComplete(op) }
            let q = try database.query("UPDATE operations SET state=?,error=?,attempts=attempts+? WHERE id=?")
            defer { sqlite3_finalize(q) }; database.bind(state.rawValue, q, 1); database.bind(errorCode, q, 2); database.bind(Int64(state == .running ? 1 : 0), q, 3); database.bind(id.uuidString, q, 4); try database.done(q)
        }
    }
    public func recordReceipt(operationID: UUID, stepID: String, validator: String? = nil) throws {
        try database.transaction { try insertReceipt(operationID: operationID, stepID: stepID, validator: validator) }
    }
    func insertReceipt(operationID: UUID, stepID: String, validator: String?) throws {
        guard try operationUnchecked(operationID) != nil else { throw NamespaceFailure.operationNotFound }
        guard !stepID.isEmpty, stepID.utf8.count <= 1024, (validator?.utf8.count ?? 0) <= 4096 else { throw NamespaceFailure.limitExceeded }
        let old = try database.query("SELECT validator FROM receipts WHERE operation=? AND step=?")
        defer { sqlite3_finalize(old) }; database.bind(operationID.uuidString, old, 1); database.bind(stepID, old, 2)
        let status = sqlite3_step(old)
        if status == SQLITE_ROW {
            let existing: String? = sqlite3_column_type(old, 0) == SQLITE_NULL ? nil : database.text(old, 0)
            guard existing == validator else { throw NamespaceFailure.generationChanged }; return
        }
        guard status == SQLITE_DONE else { throw NamespaceFailure.storage }
        let q = try database.query("INSERT INTO receipts(operation,step,validator,recorded) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(q) }; database.bind(operationID.uuidString, q, 1); database.bind(stepID, q, 2); database.bind(validator, q, 3); database.bind(Date().timeIntervalSince1970, q, 4); try database.done(q)
    }
    public func receipts(operationID: UUID) throws -> [NamespaceReceipt] {
        try database.validate(); let q = try database.query("SELECT step,validator,recorded FROM receipts WHERE operation=? ORDER BY step")
        defer { sqlite3_finalize(q) }; database.bind(operationID.uuidString, q, 1); var result: [NamespaceReceipt] = []
        while true {
            let status = sqlite3_step(q); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw NamespaceFailure.storage }
            result.append(NamespaceReceipt(operationID: operationID, stepID: database.text(q, 0), validator: sqlite3_column_type(q, 1) == SQLITE_NULL ? nil : database.text(q, 1), recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(q, 2))))
        }
        return result
    }
    public func completeOperation(_ id: UUID) throws {
        try database.transaction {
            guard let op = try operationUnchecked(id) else { throw NamespaceFailure.operationNotFound }
            if op.state == .complete { return }
            try assertDependenciesComplete(op)
            let proof = try database.query("SELECT 1 FROM receipts WHERE operation=? LIMIT 1"); defer { sqlite3_finalize(proof) }; database.bind(id.uuidString, proof, 1)
            guard sqlite3_step(proof) == SQLITE_ROW else { throw NamespaceFailure.invalidTransition }
            let q = try database.query("UPDATE operations SET state='complete',error=NULL WHERE id=?"); defer { sqlite3_finalize(q) }; database.bind(id.uuidString, q, 1); try database.done(q)
            // Never advertise later local revisions as published while an earlier op is unresolved.
            try database.exec("UPDATE volume SET published=MAX(published,COALESCE((SELECT MIN(sequence)-1 FROM operations WHERE state!='complete'),revision))")
        }
    }
    public func events(after sequence: Int64 = 0, limit: Int = 256) throws -> [NamespaceEvent] {
        try database.validate(); guard sequence >= 0, (1...10_000).contains(limit) else { throw NamespaceFailure.limitExceeded }
        let q = try database.query("SELECT sequence,node,revision,kind FROM events WHERE sequence>? ORDER BY sequence LIMIT ?")
        defer { sqlite3_finalize(q) }; database.bind(sequence, q, 1); database.bind(Int64(limit), q, 2)
        var result: [NamespaceEvent] = []
        while true {
            let status = sqlite3_step(q); if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let node = UUID(uuidString: database.text(q, 1)), let kind = NamespaceOperationKind(rawValue: database.text(q, 3)) else { throw NamespaceFailure.corrupt }
            result.append(NamespaceEvent(sequence: sqlite3_column_int64(q, 0), nodeID: node, revision: sqlite3_column_int64(q, 2), kind: kind))
        }
        return result
    }
    func insertEvent(nodeID: UUID, revision: Int64, kind: NamespaceOperationKind) throws {
        let q = try database.query("INSERT INTO events(node,revision,kind) VALUES(?,?,?)"); defer { sqlite3_finalize(q) }
        database.bind(nodeID.uuidString, q, 1); database.bind(revision, q, 2); database.bind(kind.rawValue, q, 3); try database.done(q)
    }
    func insertOperation(kind: NamespaceOperationKind, node: NamespaceNode, revision: Int64, source: String?, destination: String?, replaced: UUID? = nil, snapshot: UUID? = nil, checksum: String? = nil, modifiedAt: Date? = nil, operationID: UUID? = nil, requestDigest: String, localOnly: Bool = false) throws -> NamespaceOperation {
        // A conservative sequence dependency avoids scanning a moved subtree to find
        // pending descendants. Remote steps within one operation may still run in parallel.
        let previous = try database.query("SELECT id FROM operations ORDER BY sequence DESC LIMIT 1"); defer { sqlite3_finalize(previous) }
        let dependencies: [UUID]
        if sqlite3_step(previous) == SQLITE_ROW, let id = UUID(uuidString: database.text(previous, 0)), let prior = try operationUnchecked(id) {
            // An unlinked handle write completes locally before its remote predecessors.
            // It cannot become a false barrier that permits later path reuse too early.
            dependencies = prior.localOnly == true ? prior.dependencies : [id]
        } else { dependencies = [] }
        let snapshotNode = try rawNode(node.id)
        let parents = try Set([node.parentID, snapshotNode.parentID].compactMap { $0 }).map { try rawNode($0) }
        let base = kind == .write ? node.contentGeneration : node.metadataGeneration
        let op = NamespaceOperation(id: operationID ?? UUID(), sequence: revision, requestDigest: requestDigest, kind: kind, nodeID: node.id,
                                    baseGeneration: base, targetGeneration: base + (kind == .create ? 0 : 1), sourcePath: source, destinationPath: destination,
                                    sourceLocator: node.backing, replacedNodeID: replaced, stagedSnapshotID: snapshot, contentChecksum: checksum, modifiedAt: modifiedAt, nodeSnapshot: snapshotNode, parentSnapshots: parents, localOnly: localOnly,
                                    dependencies: dependencies, state: localOnly ? .complete : .pending, attemptCount: 0, errorCode: nil)
        let q = try database.query("INSERT INTO operations(id,sequence,node,kind,state,payload) VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(q) }; database.bind(op.id.uuidString, q, 1); database.bind(revision, q, 2); database.bind(node.id.uuidString, q, 3); database.bind(kind.rawValue, q, 4); database.bind(op.state.rawValue, q, 5); database.bind(try JSONEncoder().encode(op), q, 6); try database.done(q)
        for dependency in dependencies {
            let d = try database.query("INSERT INTO dependencies(operation,dependency) VALUES(?,?)"); defer { sqlite3_finalize(d) }
            database.bind(op.id.uuidString, d, 1); database.bind(dependency.uuidString, d, 2); try database.done(d)
        }
        if localOnly {
            let proof = try database.query("INSERT INTO receipts(operation,step,validator,recorded) VALUES(?,'local-unlinked-content',NULL,?)")
            defer { sqlite3_finalize(proof) }; database.bind(op.id.uuidString, proof, 1); database.bind(Date().timeIntervalSince1970, proof, 2); try database.done(proof)
        }
        try insertHistory(snapshotNode, revision: revision)
        for parent in parents { try insertHistory(parent, revision: revision) }
        try insertEvent(nodeID: node.id, revision: revision, kind: kind)
        if let replaced {
            try insertHistory(try rawNode(replaced), revision: revision)
            try insertEvent(nodeID: replaced, revision: revision, kind: .remove)
        }
        return op
    }
    func operationUnchecked(_ id: UUID) throws -> NamespaceOperation? {
        let q = try database.query("SELECT payload,state,attempts,error FROM operations WHERE id=?"); defer { sqlite3_finalize(q) }; database.bind(id.uuidString, q, 1)
        let status = sqlite3_step(q); if status == SQLITE_DONE { return nil }; guard status == SQLITE_ROW else { throw NamespaceFailure.storage }
        let op = try JSONDecoder().decode(NamespaceOperation.self, from: database.data(q, 0))
        guard op.id == id, let state = NamespaceOperationState(rawValue: database.text(q, 1)) else { throw NamespaceFailure.corrupt }
        return NamespaceOperation(id: op.id, sequence: op.sequence, requestDigest: op.requestDigest, kind: op.kind, nodeID: op.nodeID,
                                  baseGeneration: op.baseGeneration, targetGeneration: op.targetGeneration, sourcePath: op.sourcePath, destinationPath: op.destinationPath,
                                  sourceLocator: op.sourceLocator, replacedNodeID: op.replacedNodeID, stagedSnapshotID: op.stagedSnapshotID, contentChecksum: op.contentChecksum, modifiedAt: op.modifiedAt, nodeSnapshot: op.nodeSnapshot, parentSnapshots: op.parentSnapshots, localOnly: op.localOnly,
                                  dependencies: op.dependencies, state: state, attemptCount: Int(sqlite3_column_int64(q, 2)), errorCode: sqlite3_column_type(q, 3) == SQLITE_NULL ? nil : database.text(q, 3))
    }
    func pendingOperationIDs(nodeID: UUID) throws -> [UUID] {
        let q = try database.query("SELECT id FROM operations WHERE node=? AND state!='complete'"); defer { sqlite3_finalize(q) }; database.bind(nodeID.uuidString, q, 1)
        var result: [UUID] = []
        while sqlite3_step(q) == SQLITE_ROW { guard let id = UUID(uuidString: database.text(q, 0)) else { throw NamespaceFailure.corrupt }; result.append(id) }
        return result
    }
    func assertDependenciesComplete(_ op: NamespaceOperation) throws {
        for id in op.dependencies { guard let dependency = try operationUnchecked(id), dependency.state == .complete else { throw NamespaceFailure.invalidTransition } }
    }
    func replay(_ id: UUID?, digest: String) throws -> NamespaceOperation? {
        guard let id, let previous = try operationUnchecked(id) else { return nil }
        guard previous.requestDigest == digest else { throw NamespaceFailure.invalidTransition }; return previous
    }
    func requestDigest(_ request: NamespaceMutationRequest) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
    }
}

struct NamespaceMutationRequest: Codable {
    let kind: NamespaceOperationKind
    var node: UUID? = nil
    var parent: UUID? = nil
    var name: String? = nil
    var nodeKind: NamespaceNodeKind? = nil
    var backing: ObjectLocator? = nil
    var replace: Bool? = nil
    var recursive: Bool? = nil
    var expectedGeneration: Int64? = nil
    var newSize: Int64? = nil
    var snapshot: UUID? = nil
    var checksum: String? = nil
    var modifiedAt: Date? = nil
    var allowUnlinked: Bool? = nil
    var xattrPolicy: String? = nil
}

extension NamespaceStore {
    /// Historical upload receipts survive newer dirty generations; only a matching
    /// current generation changes the node's backing or clears its staged snapshot.
    public func recordPublishedContent(nodeID: NodeID, generation: Int64, backing: ObjectLocator) throws {
        try database.transaction {
            try Self.validateLocator(backing); let node = try rawNode(nodeID)
            guard generation >= 0, generation <= node.contentGeneration else { throw NamespaceFailure.generationChanged }
            if generation == node.contentGeneration { guard node.size == backing.size else { throw NamespaceFailure.generationChanged } }
            try recordPublishedContentUnchecked(nodeID: nodeID, generation: generation, backing: backing, updateCurrent: node.contentGeneration == generation)
        }
    }
    func recordPublishedContentUnchecked(nodeID: UUID, generation: Int64, backing: ObjectLocator, updateCurrent: Bool, allowRelocation: Bool = false) throws {
        let encoded = try JSONEncoder().encode(backing)
        let old = try database.query("SELECT size,locator FROM content WHERE node=? AND generation=?")
        defer { sqlite3_finalize(old) }; database.bind(nodeID.uuidString, old, 1); database.bind(generation, old, 2)
        if sqlite3_step(old) == SQLITE_ROW {
            guard sqlite3_column_int64(old, 0) == backing.size else { throw NamespaceFailure.generationChanged }
            if sqlite3_column_type(old, 1) != SQLITE_NULL {
                let previous = try JSONDecoder().decode(ObjectLocator.self, from: database.data(old, 1))
                // A generation may relocate only through a separately verified move.
                guard previous == backing || allowRelocation else { throw NamespaceFailure.generationChanged }
            }
        }
        let q = try database.query("INSERT INTO content(node,generation,snapshot,size,checksum,published,locator) VALUES(?,?,'',?,?,1,?) ON CONFLICT(node,generation) DO UPDATE SET published=1,locator=excluded.locator")
        defer { sqlite3_finalize(q) }; database.bind(nodeID.uuidString, q, 1); database.bind(generation, q, 2); database.bind(backing.size, q, 3); database.bind(backing.checksum, q, 4); database.bind(encoded, q, 5); try database.done(q)
        if updateCurrent {
            let n = try database.query("UPDATE nodes SET backing=? WHERE id=? AND content_generation=?")
            defer { sqlite3_finalize(n) }; database.bind(encoded, n, 1); database.bind(nodeID.uuidString, n, 2); database.bind(generation, n, 3); try database.done(n)
        }
    }
    /// Called only after a durable verified-copy receipt. The compare-and-swap
    /// prevents a stale relocation from retargeting a newer content generation.
    public func markContentRelocated(nodeID: NodeID, generation: Int64, expectedBacking: ObjectLocator, backing: ObjectLocator) throws {
        try database.transaction {
            try Self.validateLocator(backing); let node = try rawNode(nodeID)
            guard generation >= 0, generation <= node.contentGeneration, expectedBacking.size == backing.size,
                  try publishedLocator(nodeID: nodeID, generation: generation) == expectedBacking else { throw NamespaceFailure.generationChanged }
            if generation == node.contentGeneration { guard node.size == backing.size, node.backing == expectedBacking else { throw NamespaceFailure.generationChanged } }
            try recordPublishedContentUnchecked(nodeID: nodeID, generation: generation, backing: backing, updateCurrent: generation == node.contentGeneration, allowRelocation: true)
            if generation != node.contentGeneration, node.backing == expectedBacking {
                // A dirty generation may still use this older published base. Change
                // only its base locator; its staged bytes remain unpublished.
                let n = try database.query("UPDATE nodes SET backing=? WHERE id=?")
                defer { sqlite3_finalize(n) }; database.bind(try JSONEncoder().encode(backing), n, 1); database.bind(nodeID.uuidString, n, 2); try database.done(n)
            }
        }
    }
    public func publishedLocator(nodeID: NodeID, generation: Int64) throws -> ObjectLocator? {
        try database.validate(); let q = try database.query("SELECT locator FROM content WHERE node=? AND generation=? AND published=1")
        defer { sqlite3_finalize(q) }; database.bind(nodeID.uuidString, q, 1); database.bind(generation, q, 2)
        let status = sqlite3_step(q); if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, sqlite3_column_type(q, 0) != SQLITE_NULL else { throw NamespaceFailure.corrupt }
        return try JSONDecoder().decode(ObjectLocator.self, from: database.data(q, 0))
    }
}

extension NamespaceStore {
    public func managedRestoreStatus() throws -> NamespaceRestoreStatus? {
        try database.validate()
        let q = try database.query("SELECT volume,root,revision,(SELECT count(*) FROM restore_nodes) FROM restore_session")
        defer { sqlite3_finalize(q) }; let status = sqlite3_step(q); if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let volume = UUID(uuidString: database.text(q, 0)), let root = UUID(uuidString: database.text(q, 1)) else { throw NamespaceFailure.corrupt }
        return NamespaceRestoreStatus(volumeID: volume, rootID: root, revision: sqlite3_column_int64(q, 2), stagedRecords: Int(sqlite3_column_int64(q, 3)))
    }
    public func beginManagedRestore(volumeID: UUID, rootID: UUID, revision: Int64) throws {
        try database.transaction {
            let volume = try volumeUnchecked()
            guard volume.mode == .managed, volume.id == volumeID, volume.rootID == rootID,
                  revision >= 0, volume.revision == 0,
                  try database.scalar("SELECT count(*) FROM nodes") == 1,
                  try database.scalar("SELECT count(*) FROM operations") == 0 else { throw NamespaceFailure.invalidTransition }
            if let existing = try managedRestoreStatus() {
                guard existing.volumeID == volumeID, existing.rootID == rootID, existing.revision == revision else { throw NamespaceFailure.invalidTransition }; return
            }
            let q = try database.query("INSERT INTO restore_session(volume,root,revision) VALUES(?,?,?)")
            defer { sqlite3_finalize(q) }; database.bind(volumeID.uuidString, q, 1); database.bind(rootID.uuidString, q, 2); database.bind(revision, q, 3); try database.done(q)
        }
    }
    public func stageManagedRestore(_ records: [ManagedNodeRecord]) throws {
        guard records.count <= 10_000 else { throw NamespaceFailure.limitExceeded }
        try database.transaction {
            guard try managedRestoreStatus() != nil else { throw NamespaceFailure.invalidTransition }
            var admitted = try database.scalar("SELECT count(*) FROM restore_nodes")
            var admittedBytes = try database.scalar("SELECT COALESCE(SUM(length(payload)),0) FROM restore_nodes")
            for record in records {
                guard record.size >= 0, record.generation >= 0, record.generation < Int64.max, (record.metadataGeneration ?? 0) >= 0, (record.metadataGeneration ?? 0) < Int64.max, record.modifiedAt.timeIntervalSince1970.isFinite else { throw NamespaceFailure.corrupt }
                if let values = record.xattrs { try ManagedXattrs.validate(values) }
                if let backing = record.backing { try Self.validateLocator(backing); guard backing.size == record.size else { throw NamespaceFailure.corrupt } }
                if record.parentID != nil { try Self.validateName(record.name) }
                let existing = try database.query("SELECT payload FROM restore_nodes WHERE id=?")
                defer { sqlite3_finalize(existing) }; database.bind(record.id.uuidString, existing, 1)
                if sqlite3_step(existing) == SQLITE_ROW {
                    guard try JSONDecoder().decode(ManagedNodeRecord.self, from: database.data(existing, 0)) == record else { throw NamespaceFailure.generationChanged }; continue
                }
                let payload = try JSONEncoder().encode(record)
                guard admitted < 1_000_000, Int64(payload.count) <= 128 * 1024 * 1024 - admittedBytes else { throw NamespaceFailure.limitExceeded }
                admitted += 1; admittedBytes += Int64(payload.count)
                let q = try database.query("INSERT INTO restore_nodes(id,payload) VALUES(?,?)")
                defer { sqlite3_finalize(q) }; database.bind(record.id.uuidString, q, 1); database.bind(payload, q, 2); try database.done(q)
            }
        }
    }
    public func finishManagedRestore() throws {
        try database.transaction {
            guard let session = try managedRestoreStatus(), try database.scalar("SELECT count(*) FROM nodes") == 1,
                  try database.scalar("SELECT count(*) FROM operations") == 0 else { throw NamespaceFailure.invalidTransition }
            guard try database.scalar("SELECT COALESCE(SUM(length(payload)),0) FROM restore_nodes") <= 128 * 1024 * 1024 else { throw NamespaceFailure.limitExceeded }
            let q = try database.query("SELECT payload FROM restore_nodes"); defer { sqlite3_finalize(q) }
            var records: [UUID: ManagedNodeRecord] = [:], children: [UUID: [ManagedNodeRecord]] = [:]
            while true {
                let status = sqlite3_step(q); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw NamespaceFailure.storage }
                let record = try JSONDecoder().decode(ManagedNodeRecord.self, from: database.data(q, 0)); records[record.id] = record
                if let parent = record.parentID { children[parent, default: []].append(record) }
            }
            guard let root = records[session.rootID], root.parentID == nil, root.kind == .directory, root.name.isEmpty,
                  root.size == 0, root.backing == nil, records.values.filter({ $0.parentID == nil }).count == 1 else { throw NamespaceFailure.corrupt }
            // Validate the complete graph before making any imported node visible.
            var ordered: [(ManagedNodeRecord, Int)] = [(root, 0)], seen = Set<UUID>([root.id]), cursor = 0
            while cursor < ordered.count {
                let (parent, depth) = ordered[cursor]; cursor += 1
                let descendants = children[parent.id] ?? []
                if !descendants.isEmpty { guard parent.kind == .directory, depth < 4096 else { throw NamespaceFailure.corrupt } }
                var names = Set<String>()
                for child in descendants {
                    guard seen.insert(child.id).inserted, names.insert(Self.comparison(child.name)).inserted else { throw NamespaceFailure.collision }
                    ordered.append((child, depth + 1))
                }
            }
            guard seen.count == records.count else { throw NamespaceFailure.corrupt }
            var nativeIDs = Set<Int64>(), maximumInode: Int64 = 2
            for (record, _) in ordered {
                guard let inode = record.inode, inode > 0,
                      record.id == session.rootID ? inode == 2 : inode > 2,
                      nativeIDs.insert(inode).inserted else { throw NamespaceFailure.incompatibleSchema }
                maximumInode = max(maximumInode, inode)
            }
            guard maximumInode < Int64.max - Int64(records.count) - 1 else { throw NamespaceFailure.limitExceeded }
            // Temporary allocations sit above every imported ID, so assigning a
            // restored inode cannot collide with a not-yet-rebased imported node.
            let allocation = try database.query("UPDATE volume SET next_inode=?")
            defer { sqlite3_finalize(allocation) }; database.bind(maximumInode + 1, allocation, 1); try database.done(allocation)
            let rootUpdate = try database.query("UPDATE nodes SET modified=?,content_generation=?,metadata_generation=? WHERE id=?")
            defer { sqlite3_finalize(rootUpdate) }; database.bind(root.modifiedAt.timeIntervalSince1970, rootUpdate, 1); database.bind(root.generation, rootUpdate, 2); database.bind(root.metadataGeneration ?? 0, rootUpdate, 3); database.bind(root.id.uuidString, rootUpdate, 4); try database.done(rootUpdate)
            for (record, _) in ordered.dropFirst() {
                guard let parent = record.parentID else { throw NamespaceFailure.corrupt }
                try insertNode(id: record.id, parent: parent, name: record.name, kind: record.kind, size: record.size, modified: record.modifiedAt, backing: nil)
                let n = try database.query("UPDATE nodes SET content_generation=?,backing=?,metadata_generation=?,inode=? WHERE id=?")
                defer { sqlite3_finalize(n) }; database.bind(record.generation, n, 1); database.bind(try record.backing.map { try JSONEncoder().encode($0) }, n, 2); database.bind(record.metadataGeneration ?? 0, n, 3); database.bind(record.inode!, n, 4); database.bind(record.id.uuidString, n, 5); try database.done(n)
                if let backing = record.backing { try recordPublishedContentUnchecked(nodeID: record.id, generation: record.generation, backing: backing, updateCurrent: true) }
                try insertEvent(nodeID: record.id, revision: session.revision, kind: .create)
            }
            let restoreAttributes = try database.query("UPDATE nodes SET xattrs=? WHERE id=?")
            defer { sqlite3_finalize(restoreAttributes) }
            for (record, _) in ordered {
                guard let values = record.xattrs else { continue }
                sqlite3_reset(restoreAttributes)
                database.bind(try JSONEncoder().encode(values), restoreAttributes, 1)
                database.bind(record.id.uuidString, restoreAttributes, 2)
                try database.done(restoreAttributes)
            }
            try database.exec("DELETE FROM node_history")
            for (record, _) in ordered { try insertHistory(try rawNode(record.id), revision: session.revision) }
            let v = try database.query("UPDATE volume SET revision=?,published=?"); defer { sqlite3_finalize(v) }; database.bind(session.revision, v, 1); database.bind(session.revision, v, 2); try database.done(v)
            try database.exec("DELETE FROM restore_nodes; DELETE FROM restore_session")
        }
    }
    public func restoreManaged(records: [ManagedNodeRecord], volumeID: UUID, revision: Int64) throws {
        let roots = records.filter { $0.parentID == nil }; guard roots.count == 1 else { throw NamespaceFailure.corrupt }
        try beginManagedRestore(volumeID: volumeID, rootID: roots[0].id, revision: revision)
        for offset in stride(from: 0, to: records.count, by: 10_000) { try stageManagedRestore(Array(records[offset..<min(offset + 10_000, records.count)])) }
        try finishManagedRestore()
    }
    func ensureNotRestoring() throws {
        if try database.scalar("SELECT count(*) FROM restore_session") != 0 { throw NamespaceFailure.invalidTransition }
    }
}

extension NamespaceStore {
    /// A relocation executes the namespace that was accepted at this revision,
    /// even if later local edits have already moved children or staged new bytes.
    public func nodeAsOf(_ id: NodeID, revision: Int64) throws -> NamespaceNode {
        try database.validate(); try ensureNotRestoring()
        guard revision >= 0, revision <= (try volumeUnchecked().revision) else { throw NamespaceFailure.invalidTransition }
        try ensureHistoryBaseline()
        let value = try historicalNode(id, revision: revision); try assertHistoricallyVisible(value, revision: revision); return value
    }
    func hasNativeMetadataForExport(root: UUID, revision: Int64) throws -> Bool {
        _ = try nodeAsOf(root, revision: revision)
        // Follow the frozen visible tree, like listAsOf. Tombstoned directories
        // and metadata deleted before this export cannot block an ordinary export.
        let query = try database.query("""
            WITH RECURSIVE visible(node,revision) AS (
                SELECT node,MAX(revision) FROM node_history WHERE node=? AND revision<=? GROUP BY node
                UNION ALL
                SELECT h.node,h.revision FROM visible v JOIN node_history h ON h.parent=v.node
                WHERE h.deleted=0 AND h.revision=(SELECT MAX(c.revision) FROM node_history c WHERE c.node=h.node AND c.revision<=?)
            )
            SELECT 1 FROM visible v JOIN node_history h ON h.node=v.node AND h.revision=v.revision
            WHERE EXISTS(SELECT 1 FROM json_each(CAST(h.payload AS TEXT),'$.xattrs')) LIMIT 1
            """)
        defer { sqlite3_finalize(query) }
        database.bind(root.uuidString, query, 1)
        database.bind(revision, query, 2)
        database.bind(revision, query, 3)
        switch sqlite3_step(query) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw NamespaceFailure.storage
        }
    }
    public func listAsOf(parentID: NodeID, revision: Int64, after: String? = nil, limit: Int = 256) throws -> NamespacePage {
        let parent = try nodeAsOf(parentID, revision: revision)
        guard parent.kind == .directory else { throw NamespaceFailure.notDirectory }
        guard (1...10_000).contains(limit), after == nil || UUID(uuidString: after!) != nil else { throw NamespaceFailure.limitExceeded }
        let q = try database.query("SELECT h.payload FROM node_history h WHERE h.parent=? AND h.node>? AND h.revision<=? AND h.deleted=0 AND h.revision=(SELECT MAX(v.revision) FROM node_history v WHERE v.node=h.node AND v.revision<=?) ORDER BY h.node LIMIT ?")
        defer { sqlite3_finalize(q) }; database.bind(parentID.uuidString, q, 1); database.bind(after.flatMap { UUID(uuidString: $0)?.uuidString } ?? "", q, 2); database.bind(revision, q, 3); database.bind(revision, q, 4); database.bind(Int64(limit + 1), q, 5)
        var nodes: [NamespaceNode] = []
        while true {
            let status = sqlite3_step(q); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw NamespaceFailure.storage }
            nodes.append(try JSONDecoder().decode(NamespaceNode.self, from: database.data(q, 0)))
        }
        let more = nodes.count > limit; if more { nodes.removeLast() }
        return NamespacePage(nodes: nodes, next: more ? nodes.last?.id.uuidString : nil, revision: revision)
    }
    func historicalNode(_ id: UUID, revision: Int64) throws -> NamespaceNode {
        let q = try database.query("SELECT payload FROM node_history WHERE node=? AND revision<=? ORDER BY revision DESC LIMIT 1")
        defer { sqlite3_finalize(q) }; database.bind(id.uuidString, q, 1); database.bind(revision, q, 2)
        guard sqlite3_step(q) == SQLITE_ROW else { throw NamespaceFailure.notFound }
        return try JSONDecoder().decode(NamespaceNode.self, from: database.data(q, 0))
    }
    func assertHistoricallyVisible(_ node: NamespaceNode, revision: Int64) throws {
        var current = node; var seen = Set<UUID>()
        while true {
            guard current.deletedRevision == nil else { throw NamespaceFailure.notFound }
            guard seen.insert(current.id).inserted, seen.count <= 4096 else { throw NamespaceFailure.corrupt }
            guard let parent = current.parentID else { break }; current = try historicalNode(parent, revision: revision)
        }
    }
    func insertHistory(_ node: NamespaceNode, revision: Int64) throws {
        let q = try database.query("INSERT INTO node_history(node,revision,parent,deleted,payload) VALUES(?,?,?,?,?) ON CONFLICT(node,revision) DO UPDATE SET parent=excluded.parent,deleted=excluded.deleted,payload=excluded.payload")
        defer { sqlite3_finalize(q) }; database.bind(node.id.uuidString, q, 1); database.bind(revision, q, 2); database.bind(node.parentID?.uuidString, q, 3); database.bind(Int64(node.deletedRevision == nil ? 0 : 1), q, 4); database.bind(try JSONEncoder().encode(node), q, 5); try database.done(q)
        try updateNameProjection(node)
    }
    func ensureHistoryBaseline() throws {
        if try database.scalar("SELECT EXISTS(SELECT 1 FROM node_history LIMIT 1)") != 0 { return }
        let revision = try volumeUnchecked().revision
        let q = try database.query("SELECT id FROM nodes"); defer { sqlite3_finalize(q) }
        var ids: [UUID] = []
        while sqlite3_step(q) == SQLITE_ROW { guard let id = UUID(uuidString: database.text(q, 0)) else { throw NamespaceFailure.corrupt }; ids.append(id) }
        // This executes once for a new root (or a verified development baseline).
        for id in ids { try insertHistory(try rawNode(id), revision: revision) }
    }
}


extension NamespaceStore {
    /// Called only after the engine has independently verified the committed remote
    /// root. Importing known content does not itself publish a managed namespace.
    public func recordNamespacePublication(revision: Int64, validator: String) throws {
        try database.transaction {
            let volume = try volumeUnchecked()
            guard volume.mode == .managed, revision >= 0, revision <= volume.revision,
                  !validator.isEmpty, validator.utf8.count <= 4096 else { throw NamespaceFailure.invalidTransition }
            let pending = try database.query("SELECT 1 FROM operations WHERE sequence<=? AND state!='complete' LIMIT 1")
            defer { sqlite3_finalize(pending) }; database.bind(revision, pending, 1)
            guard sqlite3_step(pending) == SQLITE_DONE else { throw NamespaceFailure.invalidTransition }
            let old = try database.query("SELECT validator FROM namespace_publications WHERE revision=?")
            defer { sqlite3_finalize(old) }; database.bind(revision, old, 1)
            if sqlite3_step(old) == SQLITE_ROW { guard database.text(old, 0) == validator else { throw NamespaceFailure.generationChanged } }
            let proof = try database.query("INSERT INTO namespace_publications(revision,validator) VALUES(?,?) ON CONFLICT(revision) DO NOTHING")
            defer { sqlite3_finalize(proof) }; database.bind(revision, proof, 1); database.bind(validator, proof, 2); try database.done(proof)
            let update = try database.query("UPDATE volume SET published=MAX(published,?)")
            defer { sqlite3_finalize(update) }; database.bind(revision, update, 1); try database.done(update)
        }
    }
}

extension NamespaceStore {
    func closeMayReleaseSnapshot(_ held: NamespaceNode) throws -> Bool {
        try database.validate()
        let query = try database.query("""
            SELECT EXISTS(SELECT 1 FROM content WHERE node=? AND generation=? AND published=1 AND snapshot=?)
                OR EXISTS(SELECT 1 FROM operations o JOIN receipts r ON r.operation=o.id
                    WHERE o.node=? AND o.state='complete'
                    AND (r.step='local-unlinked-content' OR (r.step='managed-superseded' AND r.validator=?)))
            """)
        defer { sqlite3_finalize(query) }
        let id = held.id.uuidString, snapshot = held.stagedSnapshotID?.uuidString
        database.bind(id, query, 1); database.bind(held.contentGeneration, query, 2)
        database.bind(snapshot, query, 3); database.bind(id, query, 4); database.bind(snapshot, query, 5)
        guard sqlite3_step(query) == SQLITE_ROW else { throw NamespaceFailure.storage }
        return sqlite3_column_int(query, 0) != 0
    }

    /// GC admission derives from authoritative receipts, never filename age. Older
    /// unpublished generations and uncertain operations remain protected conservatively.
    public func snapshotInventory() throws -> (accepted: Set<UUID>, published: Set<UUID>, pending: Set<UUID>, discarded: Set<UUID>, unpublishedByNode: [NodeID: Set<UUID>]) {
        try database.validate()
        var retired = Set<UUID>()
        let superseded = try database.query("SELECT validator FROM receipts WHERE step='managed-superseded'")
        defer { sqlite3_finalize(superseded) }
        while true {
            let status = sqlite3_step(superseded)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(superseded, 0)) else { throw NamespaceFailure.corrupt }
            retired.insert(id)
        }
        let q = try database.query("SELECT snapshot,published,node FROM content WHERE snapshot!=''")
        defer { sqlite3_finalize(q) }
        var accepted = Set<UUID>(), published = Set<UUID>(), pending = Set<UUID>(), discarded = Set<UUID>()
        var unpublishedByNode: [NodeID: Set<UUID>] = [:]
        while true {
            let status = sqlite3_step(q); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)) else { throw NamespaceFailure.corrupt }
            accepted.insert(id)
            if retired.contains(id) { discarded.insert(id) }
            else if sqlite3_column_int64(q, 1) == 1 { published.insert(id) } else {
                pending.insert(id)
                guard let nodeID = UUID(uuidString: database.text(q, 2)) else { throw NamespaceFailure.corrupt }
                unpublishedByNode[nodeID, default: []].insert(id)
            }
        }
        // Reclamation only needs the top-level snapshot reference. Decoding
        // entire operations also decodes node snapshots, parents, and xattrs.
        let operations = try database.query("""
            SELECT json_extract(CAST(payload AS TEXT), '$.stagedSnapshotID')
            FROM operations WHERE state!='complete' AND kind='write'
            """)
        defer { sqlite3_finalize(operations) }
        while true {
            let status = sqlite3_step(operations); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw NamespaceFailure.storage }
            guard sqlite3_column_type(operations, 0) == SQLITE_TEXT,
                  let id = UUID(uuidString: database.text(operations, 0)) else { throw NamespaceFailure.corrupt }
            accepted.insert(id); pending.insert(id)
        }
        // Only locally completed unlinked writes can be discarded without a cloud
        // receipt. Prove the tombstone is remotely completed and every dependency
        // finished; an uncertain remove/replacement must retain all local bytes.
        let locals = try database.query("SELECT o.id FROM operations o JOIN receipts r ON r.operation=o.id WHERE o.state='complete' AND r.step='local-unlinked-content'")
        defer { sqlite3_finalize(locals) }
        while true {
            let result = sqlite3_step(locals); if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let operationID = UUID(uuidString: database.text(locals, 0)),
                  let operation = try operationUnchecked(operationID) else { throw NamespaceFailure.corrupt }
            guard operation.localOnly == true, let snapshot = operation.stagedSnapshotID else { continue }
            guard try operation.dependencies.allSatisfy({ try operationUnchecked($0)?.state == .complete }) else { continue }
            var current = try rawNode(operation.nodeID), seen = Set<UUID>(), completedTombstone = false
            while true {
                guard seen.insert(current.id).inserted, seen.count <= 4096 else { throw NamespaceFailure.corrupt }
                if let revision = current.deletedRevision {
                    let proof = try database.query("SELECT id FROM operations WHERE sequence=? AND state='complete'")
                    defer { sqlite3_finalize(proof) }; database.bind(revision, proof, 1)
                    if sqlite3_step(proof) == SQLITE_ROW, let id = UUID(uuidString: database.text(proof, 0)), let removal = try operationUnchecked(id) {
                        completedTombstone = (removal.kind == .remove && removal.nodeID == current.id) || (removal.kind == .rename && removal.replacedNodeID == current.id)
                    }
                    break
                }
                guard let parent = current.parentID else { break }; current = try rawNode(parent)
            }
            if completedTombstone { discarded.insert(snapshot); pending.remove(snapshot) }
        }
        return (accepted, published, pending, discarded, unpublishedByNode)
    }
}

extension NamespaceStore {
    /// Freeze a bounded, contiguous create/write/metadata prefix before any cloud
    /// work. A retry uses the same endpoint even when newer writes have arrived.
    func managedPublicationBatch(first: NamespaceOperation, candidates: [NamespaceOperation]) throws -> [NamespaceOperation] {
        let proof = try receipts(operationID: first.id)
        if let checkpoint = proof.first(where: { $0.stepID == "managed-batch-end" }) {
            guard let end = checkpoint.validator.flatMap(Int64.init), end > first.sequence else { throw NamespaceFailure.corrupt }
            let q = try database.query("SELECT id FROM operations WHERE sequence>=? AND sequence<=? ORDER BY sequence LIMIT 33")
            defer { sqlite3_finalize(q) }
            database.bind(first.sequence, q, 1); database.bind(end, q, 2)
            var saved: [NamespaceOperation] = []
            while true {
                let step = sqlite3_step(q); if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)), let op = try operationUnchecked(id),
                      op.state != .complete, op.kind == .create || op.kind == .write || op.kind == .metadata else { throw NamespaceFailure.corrupt }
                saved.append(op)
            }
            guard saved.count >= 2, saved.count <= 32, saved.first?.id == first.id, saved.last?.sequence == end,
                  Int64(saved.count) == end - first.sequence + 1 else { throw NamespaceFailure.corrupt }
            return saved
        }
        var batch: [NamespaceOperation] = [], nodes = Set<NodeID>()
        for op in candidates.prefix(32) {
            guard op.state == .pending, op.attemptCount == 0, op.localOnly != true, op.replacedNodeID == nil,
                  op.kind == .create || op.kind == .write || op.kind == .metadata,
                  let node = op.nodeSnapshot, node.deletedRevision == nil,
                  batch.last.map({ op.sequence == $0.sequence + 1 }) ?? (op.id == first.id) else { break }
            let receipts = try self.receipts(operationID: op.id)
            // Legacy individual publications and folded write runs retain their
            // original recovery path. Immutable uploaded payloads are reusable.
            guard receipts.allSatisfy({ $0.stepID == "mutation-fingerprint" || $0.stepID == "uploaded" }) else { break }
            let additions = Set((op.parentSnapshots ?? []).map(\.id)).union([node.id])
            guard nodes.union(additions).count <= 255 else { break }
            nodes.formUnion(additions); batch.append(op)
        }
        // Never cut a still-contiguous Finder write run into intermediate full
        // uploads. A long run falls back to the existing durable write folding.
        if let last = batch.last, last.kind == .write {
            let q = try database.query("SELECT kind,node FROM operations WHERE sequence=?")
            defer { sqlite3_finalize(q) }; database.bind(last.sequence + 1, q, 1)
            if sqlite3_step(q) == SQLITE_ROW, database.text(q, 0) == "write", database.text(q, 1) == last.nodeID.uuidString {
                while let tail = batch.last, tail.kind == .write, tail.nodeID == last.nodeID { batch.removeLast() }
            }
        }
        guard batch.count >= 2, let last = batch.last else { return [] }
        try recordReceipt(operationID: first.id, stepID: "managed-batch-end", validator: String(last.sequence))
        return batch
    }

    /// Publication and final content locators must be durable before advancing
    /// any member. All states/retirement receipts advance in one transaction.
    func completeManagedPublicationBatch(_ batch: [NamespaceOperation]) throws {
        guard let first = batch.first, let last = batch.last, (2...32).contains(batch.count) else { throw NamespaceFailure.invalidTransition }
        try database.transaction {
            guard try receipts(operationID: first.id).contains(where: { $0.stepID == "managed-batch-end" && $0.validator == String(last.sequence) }),
                  try receipts(operationID: first.id).contains(where: { $0.stepID == "managed-batch-intent" }) else { throw NamespaceFailure.invalidTransition }
            var finalWrites: [NodeID: NamespaceOperation] = [:]
            for op in batch where op.kind == .write { finalWrites[op.nodeID] = op }
            for op in finalWrites.values {
                guard try publishedLocator(nodeID: op.nodeID, generation: op.targetGeneration) != nil else { throw NamespaceFailure.invalidTransition }
            }
            let finish = try database.query("UPDATE operations SET state='complete',error=NULL WHERE id=? AND state!='complete'")
            defer { sqlite3_finalize(finish) }
            for op in batch {
                try assertDependenciesComplete(op)
                if op.kind == .write, finalWrites[op.nodeID]?.id != op.id {
                    guard let snapshot = op.stagedSnapshotID else { throw NamespaceFailure.corrupt }
                    try insertReceipt(operationID: op.id, stepID: "managed-superseded", validator: snapshot.uuidString)
                } else {
                    try insertReceipt(operationID: op.id, stepID: "finished", validator: String(op.sequence))
                }
                sqlite3_reset(finish); database.bind(op.id.uuidString, finish, 1); try database.done(finish)
            }
            try database.exec("UPDATE volume SET published=MAX(published,COALESCE((SELECT MIN(sequence)-1 FROM operations WHERE state!='complete'),revision))")
        }
    }

    // Fix the exact group before starting a provider request. On restart the
    // first operation names the same final generation even if newer writes exist.
    func managedWriteRun(first: NamespaceOperation, allowNew: Bool) throws -> [NamespaceOperation] {
        guard first.kind == .write else { return [] }
        let checkpoint = try receipts(operationID: first.id).first { $0.stepID == "managed-write-end" }
        let replayEnd = checkpoint?.validator.flatMap(Int64.init)
        if checkpoint != nil && replayEnd == nil { throw NamespaceFailure.corrupt }
        guard replayEnd != nil || allowNew else { return [] }
        let q = try database.query("""
            SELECT id FROM operations WHERE sequence>=? AND sequence<=?
            ORDER BY sequence LIMIT 8192
            """)
        defer { sqlite3_finalize(q) }
        database.bind(first.sequence, q, 1); database.bind(replayEnd ?? Int64.max, q, 2)
        var run: [NamespaceOperation] = []
        while true {
            let status = sqlite3_step(q)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: database.text(q, 0)),
                  let op = try operationUnchecked(id) else { throw NamespaceFailure.corrupt }
            guard op.kind == .write, op.nodeID == first.nodeID, op.stagedSnapshotID != nil,
                  op.localOnly != true, op.state != .complete, op.state != .attention else { break }
            if let prior = run.last {
                guard op.dependencies == [prior.id], op.baseGeneration == prior.targetGeneration,
                      op.sequence == prior.sequence + 1 else { break }
            }
            if replayEnd == nil {
                let proof = try receipts(operationID: id)
                // A prepared immutable upload has no publication side effects.
                // An intent or prior attempt still needs its own recovery path.
                guard op.state == .pending, op.attemptCount == 0,
                      proof.contains(where: { $0.stepID == "mutation-fingerprint" }),
                      proof.allSatisfy({ $0.stepID == "mutation-fingerprint" || $0.stepID == "uploaded" }) else { break }
            }
            run.append(op)
        }
        if let replayEnd {
            guard run.first?.id == first.id, run.count >= 2, run.last?.sequence == replayEnd else { throw NamespaceFailure.corrupt }
        } else {
            guard run.count >= 2, let last = run.last else { return [] }
            try recordReceipt(operationID: first.id, stepID: "managed-write-end", validator: String(last.sequence))
        }
        return run
    }

    // The final generation's CAS and durable locator precede this transaction.
    // Intermediate generations stay readable to live leases through their snapshots.
    func completeManagedWriteRun(_ run: [NamespaceOperation]) throws {
        guard let first = run.first, let last = run.last, run.count > 1 else { throw NamespaceFailure.invalidTransition }
        try database.transaction {
            try assertDependenciesComplete(first)
            guard try publishedLocator(nodeID: last.nodeID, generation: last.targetGeneration) != nil,
                  try receipts(operationID: first.id).contains(where: { $0.stepID == "managed-write-end" && $0.validator == String(last.sequence) }),
                  try receipts(operationID: last.id).contains(where: { $0.stepID == "managed-intent" }) else { throw NamespaceFailure.invalidTransition }
            let receipt = try database.query("INSERT INTO receipts(operation,step,validator,recorded) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(receipt) }
            let finish = try database.query("UPDATE operations SET state='complete',error=NULL WHERE id=? AND state!='complete'")
            defer { sqlite3_finalize(finish) }
            for op in run {
                guard let snapshot = op.stagedSnapshotID else { throw NamespaceFailure.corrupt }
                let final = op.id == last.id
                sqlite3_reset(receipt)
                database.bind(op.id.uuidString, receipt, 1)
                database.bind(final ? "finished" : "managed-superseded", receipt, 2)
                database.bind(final ? String(last.sequence) : snapshot.uuidString, receipt, 3)
                database.bind(Date().timeIntervalSince1970, receipt, 4)
                try database.done(receipt)
                sqlite3_reset(finish); database.bind(op.id.uuidString, finish, 1); try database.done(finish)
            }
            try database.exec("UPDATE volume SET published=MAX(published,COALESCE((SELECT MIN(sequence)-1 FROM operations WHERE state!='complete'),revision))")
        }
    }
}
