import Foundation

enum UploadSchedulingError: Error, LocalizedError, Equatable {
    case invalidMemoryRequest
    case invalidRateRequest
    case queueFull

    var errorDescription: String? {
        switch self {
        case .invalidMemoryRequest: return "This upload part exceeds the available upload memory budget. Reduce concurrency or choose a larger memory budget."
        case .invalidRateRequest: return "The upload rate request is invalid. No upload was started."
        case .queueFull: return "Too many upload operations are waiting. Pause and resume the upload queue."
        }
    }
}

/// Global payload admission across all files and part requests in one upload run.
/// Acquire before allocating/reading payload data and release after the payload is no longer retained.
actor UploadMemoryBudget {
    struct Snapshot: Equatable, Sendable {
        let used: Int64
        let peak: Int64
        let waiting: Int
        let permits: Int
    }

    private struct Waiter {
        let token: UUID
        let bytes: Int64
        let continuation: CheckedContinuation<UUID, Error>
    }

    let limit: Int64
    private let maximumWaiters: Int
    private let maximumPermits = 256
    private var used: Int64 = 0
    private var peak: Int64 = 0
    private var permits: [UUID: Int64] = [:]
    private var waiters: [Waiter] = []

    init(limit: Int64 = 256 * 1_048_576, maximumWaiters: Int = 256) {
        self.limit = max(0, limit)
        self.maximumWaiters = min(256, max(1, maximumWaiters))
    }

    func acquire(bytes: Int64) async throws -> UUID {
        try Task.checkCancellation()
        guard bytes > 0, bytes <= limit else { throw UploadSchedulingError.invalidMemoryRequest }
        let token = UUID()
        return try await withTaskCancellationHandler(operation: {
            let granted: UUID = try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if waiters.isEmpty, permits.count < maximumPermits, bytes <= limit - used {
                    reserve(token: token, bytes: bytes)
                    continuation.resume(returning: token)
                } else if waiters.count >= maximumWaiters {
                    continuation.resume(throwing: UploadSchedulingError.queueFull)
                } else {
                    waiters.append(Waiter(token: token, bytes: bytes, continuation: continuation))
                }
            }
            // Cancellation may race the continuation's successful grant. Reclaim before throwing.
            if Task.isCancelled {
                release(token: granted)
                throw CancellationError()
            }
            return granted
        }, onCancel: {
            Task { await self.cancelWaiter(token: token) }
        })
    }

    func release(token: UUID) {
        guard let bytes = permits.removeValue(forKey: token) else { return }
        used -= bytes
        drain()
    }

    func snapshot() -> Snapshot { Snapshot(used: used, peak: peak, waiting: waiters.count, permits: permits.count) }

    private func reserve(token: UUID, bytes: Int64) {
        permits[token] = bytes
        used += bytes
        peak = max(peak, used)
    }

    private func cancelWaiter(token: UUID) {
        // Never reclaim a permit here: this cancellation callback may arrive after acquire returned.
        // A racing successful acquire reclaims its own grant; callers own successfully returned tokens.
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        drain()
    }

    private func drain() {
        while let first = waiters.first, permits.count < maximumPermits, first.bytes <= limit - used {
            waiters.removeFirst()
            reserve(token: first.token, bytes: first.bytes)
            first.continuation.resume(returning: first.token)
        }
    }
}

/// Aggregate, FIFO request pacing shared by every concurrent file/part in an upload run.
/// Each request waits for its byte reservation before it starts. This limits average admitted bytes;
/// URLSession can still transmit an admitted request in a burst rather than shape individual packets.
actor UploadRateLimiter {
    struct Snapshot: Equatable, Sendable {
        let waiting: Int
        let grantedBytes: Int64
    }

    private struct Waiter {
        let token: UUID
        let bytes: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let bytesPerSecond: Int64
    private let maximumWaiters: Int
    private let clock = ContinuousClock()
    private var waiters: [Waiter] = []
    private var timer: Task<Void, Never>?
    private var timerToken: UUID?
    private var grantedBytes: Int64 = 0

    init(bytesPerSecond: Int64, maximumWaiters: Int = 256) {
        self.bytesPerSecond = bytesPerSecond
        self.maximumWaiters = min(256, max(1, maximumWaiters))
    }

    func waitToSend(bytes: Int64) async throws {
        try Task.checkCancellation()
        // R2's largest supported multipart payload is 5 GiB. This also bounds timer arithmetic.
        guard bytes >= 0, bytes <= 5 * 1_073_741_824 else { throw UploadSchedulingError.invalidRateRequest }
        guard bytes > 0 else { return }
        if bytesPerSecond <= 0 {
            recordGrant(bytes)
            return
        }
        let token = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if waiters.count >= maximumWaiters {
                    continuation.resume(throwing: UploadSchedulingError.queueFull)
                } else {
                    waiters.append(Waiter(token: token, bytes: bytes, continuation: continuation))
                    scheduleHead()
                }
            }
            try Task.checkCancellation()
        }, onCancel: {
            Task { await self.cancelWaiter(token: token) }
        })
    }

    func snapshot() -> Snapshot { Snapshot(waiting: waiters.count, grantedBytes: grantedBytes) }

    private func recordGrant(_ bytes: Int64) {
        let result = grantedBytes.addingReportingOverflow(bytes)
        grantedBytes = result.overflow ? Int64.max : result.partialValue
    }

    private func scheduleHead() {
        guard timer == nil, let first = waiters.first else { return }
        let token = first.token
        let deadline = clock.now.advanced(by: .seconds(Double(first.bytes) / Double(bytesPerSecond)))
        timerToken = token
        let clock = self.clock
        timer = Task { [weak self] in
            do { try await clock.sleep(until: deadline) }
            catch { return }
            await self?.grantHead(token: token)
        }
    }

    private func grantHead(token: UUID) {
        // A cancelled timer can finish after a replacement has been installed.
        guard timerToken == token, waiters.first?.token == token else { return }
        timer = nil; timerToken = nil
        let waiter = waiters.removeFirst()
        recordGrant(waiter.bytes)
        waiter.continuation.resume()
        scheduleHead()
    }

    private func cancelWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        if timerToken == token {
            timer?.cancel(); timer = nil; timerToken = nil
        }
        waiter.continuation.resume(throwing: CancellationError())
        scheduleHead()
    }
}
