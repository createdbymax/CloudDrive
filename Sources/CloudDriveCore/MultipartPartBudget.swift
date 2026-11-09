import Foundation

/// Shared by every multipart upload on one transport. Reservations cover reader
/// payload ranges held until their requests settle, not total URLSession memory.
actor MultipartPartBudget {
    private struct Waiter {
        let id: UUID
        let bytes: Int64
        let continuation: CheckedContinuation<UUID, Error>
    }
    private let maximumRequests: Int
    private let maximumBytes: Int64
    private var active: [UUID: Int64] = [:]
    private var queue: [Waiter] = []
    init(maximumRequests: Int = 4, maximumBytes: Int64 = 128 * 1024 * 1024) {
        self.maximumRequests = max(1, maximumRequests)
        self.maximumBytes = max(64 * 1024 * 1024, maximumBytes)
    }
    func withLease<Value: Sendable>(bytes: Int64, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = try await acquire(bytes: bytes)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(id)
            return result
        } catch { release(id); throw error }
    }
    func acquire(bytes: Int64) async throws -> UUID {
        try Task.checkCancellation()
        guard (1...min(64 * 1024 * 1024, maximumBytes)).contains(bytes) else { throw StorageFailure.invalidRange }
        let id = UUID()
        let lease = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Waiter(id: id, bytes: bytes, continuation: continuation)); pump()
            }
        } onCancel: { Task { await self.cancel(id) } }
        if Task.isCancelled { release(lease); throw CancellationError() }
        return lease
    }
    func release(_ id: UUID) { active.removeValue(forKey: id); pump() }
    private func cancel(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError()); pump()
    }
    private func pump() {
        var used = active.values.reduce(Int64(0), +)
        while let next = queue.first, active.count < maximumRequests, next.bytes <= maximumBytes - used {
            queue.removeFirst(); active[next.id] = next.bytes; used += next.bytes
            next.continuation.resume(returning: next.id)
        }
    }
    var usage: (requests: Int, bytes: Int64, waiting: Int) { (active.count, active.values.reduce(0, +), queue.count) }
}
