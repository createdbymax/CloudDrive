import Foundation

struct UploadCatalogHint: Sendable, Equatable {
    let id: String
    let destination: String
    let key: String
}
struct CatalogChange: Sendable {
    let key: String
    let recursive: Bool
    let revision: Int64
}
struct CatalogWorkerCursor: Sendable {
    let session: String?
    let sequence: Int64
}
struct WorkerMetadataChanges: Decodable, Sendable {
    struct Event: Decodable, Sendable {
        let sequence: Int64
        let path: String
        let recursive: Bool
    }
    let version: Int
    let session: String
    let first: Int64
    let latest: Int64
    let events: [Event]
    let next: Int64
    let hasMore: Bool
    let gap: Bool

    func validate(after: Int64) throws {
        guard version == 1, !session.isEmpty, !session.contains("\0"), session.utf8.count <= 128, first >= 1, latest >= 0, latest < Int64.max, after >= 0, after < Int64.max,
              first <= latest + 1, next >= 0, next <= latest, events.count <= 256,
              hasMore == (next < latest), (!hasMore || !events.isEmpty) else { throw CatalogFailure.invalidInventory }
        var expected = gap ? first - 1 : after
        for event in events {
            guard event.sequence == expected + 1, event.sequence <= latest,
                  event.path.utf8.count <= 4096, !event.path.contains("\0") else { throw CatalogFailure.invalidInventory }
            expected = event.sequence
        }
        guard next == expected else { throw CatalogFailure.invalidInventory }
    }
}

/// Drains durable hints using current remote facts. A hint is never trusted as a
/// successful PUT/DELETE: unknown or failed HEADs leave it pending for retry.
enum CatalogChangeReconciler {
    static func drain(store: CatalogStore, remote: any ObjectInventoryRemote, maximum: Int = 100, progress: @Sendable () async -> Void = {}) async throws -> Bool {
        let changes = try await store.pendingChanges(limit: maximum)
        var firstFailure: Error?
        for change in changes {
          do {
            try Task.checkCancellation()
            if change.recursive {
                var token: String?, tokens = Set<String>()
                repeat {
                    let page = try await remote.list(scope: change.key + "/", token: token)
                    try Task.checkCancellation()
                    try await store.applyChangedObjects(page.objects, change: change)
                    await progress()
                    token = page.nextToken
                    if let token, !tokens.insert(token).inserted { throw CatalogFailure.invalidInventory }
                } while token != nil
                var after: String?
                while true {
                    let keys = try await store.changedDescendants(change: change, after: after)
                    if keys.isEmpty { break }
                    var checked = 0
                    for key in keys {
                        try Task.checkCancellation()
                        let object = try await remote.head(key: key)
                        try Task.checkCancellation()
                        try await store.applyChangedObject(object, key: key, change: change)
                        after = key; checked += 1
                        if checked % 10 == 0 { await progress() }
                    }
                }
            }
            let object = try await remote.head(key: change.key)
            try Task.checkCancellation()
            try await store.applyChangedObject(object, key: change.key, change: change)
            try await store.acknowledgeChange(change)
            await progress()
          } catch {
            if Task.isCancelled { throw CancellationError() }
            if case CatalogFailure.superseded = error { continue }
            try await store.deferChange(change)
            if firstFailure == nil { firstFailure = error }
          }
        }
        if let firstFailure { throw firstFailure }
        return !changes.isEmpty
    }
}
