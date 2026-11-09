import Foundation

struct CatalogObject: Sendable, Equatable, Identifiable {
    let key: String
    let size: Int64
    let modified: Date
    let etag: String
    /// Only namespace-backed results supply an identity. Object-store ETags are not identities.
    var nodeID: UUID? = nil
    var availability: CatalogAvailability? = nil
    var availabilityCheckedAt: Date? = nil
    var id: Data { nodeID.map { Data(("namespace-node:" + $0.uuidString).utf8) } ?? Data(key.utf8) }
    var name: String { key.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? key }
    var parent: String { String(key.dropLast(name.count)) }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

struct InventoryPage: Sendable {
    let objects: [CatalogObject]
    let nextToken: String?
}

protocol ObjectInventoryRemote: Sendable {
    func list(token: String?) async throws -> InventoryPage
    func list(scope: String, token: String?) async throws -> InventoryPage
    func head(key: String) async throws -> CatalogObject?
    /// Only a confirmed not-found response returns true. Permission/errors throw.
    func isMissing(key: String) async throws -> Bool
    func close()
}

extension ObjectInventoryRemote {
    func close() {}
    func list(scope: String, token: String?) async throws -> InventoryPage { throw CatalogFailure.invalidInventory }
    func head(key: String) async throws -> CatalogObject? { throw CatalogFailure.invalidInventory }
}

struct CatalogScan: Sendable {
    let id: Int64
    let token: String?
}

struct CatalogSummary: Sendable, Equatable {
    var count: Int = 0
    var lastCompleted: Date?
    var hasPartialScan = false
}

enum CatalogFailure: Error, LocalizedError {
    case storage, incompatible, invalidInventory, http(Int), query, queryTimedOut, superseded, diskSpace, largeChange
    var errorDescription: String? {
        switch self {
        case .storage: return "The local search catalog is unavailable. Check its folder permissions and free space. Upload records are separate."
        case .incompatible: return "This catalog or SQLite search capability is incompatible with this app. The existing catalog was preserved."
        case .invalidInventory: return "The inventory response was invalid. Saved results were preserved; retry with a fresh scan."
        case .http(let code): return "Inventory refresh failed (HTTP \(code)). Saved results remain available."
        case .query: return "Use plain search words and the extension and minimum-size filters. Search is limited to 256 characters and 12 words."
        case .queryTimedOut: return "This search exceeded its time budget. Add a more specific word or filter."
        case .superseded: return "This scan has been superseded."
        case .largeChange: return "Many files were absent from this scan. Saved entries were retained while automatic indexing confirms a second complete inventory."
        case .diskSpace: return "Indexing paused because local free space is low. Saved results and uploads were preserved."
        }
    }
}

enum CatalogText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping.lowercased()
    }
    static func validate(_ object: CatalogObject, prefix: String) throws {
        guard object.key.utf8.starts(with: (prefix + "/").utf8), object.key.utf8.count <= 1024,
              !object.key.contains("\0"), object.size >= 0, object.modified.timeIntervalSince1970.isFinite,
              !object.etag.isEmpty, object.etag.utf8.count <= 1024 else { throw CatalogFailure.invalidInventory }
    }
    /// Unsafe object keys remain searchable, but cannot be resolved to a mount URL.
    static func mountURL(key: String, prefix: String, mount: URL) -> URL? {
        guard key.utf8.starts(with: (prefix + "/").utf8) else { return nil }
        let relative = String(key.dropFirst(prefix.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        return parts.reduce(mount) { $0.appendingPathComponent(String($1), isDirectory: false) }
    }
}

struct CatalogQuery: Sendable {
    let text: String
    var fileExtension = ""
    var minimumSize: Int64 = 0
    var offset: Int = 0
    var limit: Int = 50
    func terms() throws -> [String] {
        guard text.utf8.count <= 1024, text.count <= 256, fileExtension.utf8.count <= 128, fileExtension.count <= 32, minimumSize >= 0,
              (0...1000).contains(offset), (1...100).contains(limit), !text.contains("\0") else { throw CatalogFailure.query }
        let terms = CatalogText.normalize(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard terms.count <= 12, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !terms.isEmpty else { throw CatalogFailure.query }
        return terms
    }
}

enum CatalogSelection {
    /// Preserve identity across reordered/renamed rows, otherwise choose the nearest surviving position.
    static func reconcile(_ selected: Data?, previous: [CatalogObject], updated: [CatalogObject]) -> Data? {
        guard !updated.isEmpty else { return nil }
        if let selected, updated.contains(where: { $0.id == selected }) { return selected }
        let position = selected.flatMap { id in previous.firstIndex { $0.id == id } } ?? 0
        return updated[min(position, updated.count - 1)].id
    }
}

/// Availability is supplied by the namespace owner after checking the current content generation.
/// Object-store listings never provide this proof.
enum CatalogAvailability: String, Sendable, CaseIterable {
    case remoteOnly, downloading, availableOffline, attention, unknown
    var label: String {
        switch self {
        case .remoteOnly: return "Needs internet"
        case .downloading: return "Downloading for offline use"
        case .availableOffline: return "Available offline"
        case .attention: return "Offline download needs attention"
        case .unknown: return "Availability unknown"
        }
    }
    var symbol: String {
        switch self {
        case .remoteOnly: return "icloud"
        case .downloading: return "arrow.down.circle"
        case .availableOffline: return "checkmark.circle"
        case .attention: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }
    static func effective(_ value: Self?, checkedAt: Date?, at date: Date) -> Self? {
        guard let value else { return nil }
        return UploadFreshness.isFresh(checkedAt, at: date) ? value : .unknown
    }
}
