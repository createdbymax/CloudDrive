import Foundation

protocol UploadRateClock: Sendable {
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}
private struct SystemUploadRateClock: UploadRateClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Shared FIFO admission budget for outgoing request bodies. Zero means unlimited.
/// The transport buffers a part before sending, so wire bursts are bounded by its
/// part size (at most 64 MiB), not smoothed packet-by-packet by this component.
public actor UploadBandwidthLimiter {
    public static let maximumAdmissionBytes = 64 * 1024 * 1024
    public static let maximumRate: Int64 = 1_099_511_627_776
    private let clock: any UploadRateClock
    private var rate: Int64
    private var tokens: Double = 0
    private var lastRefill: TimeInterval
    private struct Waiter { let id: UUID; let bytes: Int; let continuation: CheckedContinuation<Void, Error> }
    private var queue: [Waiter] = []
    private var timer: Task<Void, Never>?
    private var timerGeneration: UInt64 = 0

    public init(initialBytesPerSecond: Int64 = 0) {
        let clock = SystemUploadRateClock()
        self.clock = clock; lastRefill = clock.now()
        rate = min(Self.maximumRate, max(0, initialBytesPerSecond))
    }
    init(initialBytesPerSecond: Int64, clock: any UploadRateClock) {
        self.clock = clock; lastRefill = clock.now()
        rate = min(Self.maximumRate, max(0, initialBytesPerSecond))
    }
    public func rateBytesPerSecond() -> Int64 { rate }
    var pendingRequests: Int { queue.count }
    public func setRate(bytesPerSecond: Int64) throws {
        guard (0...Self.maximumRate).contains(bytesPerSecond) else { throw StorageFailure.invalidRange }
        guard bytesPerSecond != rate else { return }
        // A newly selected cap starts with no inherited unlimited/old-rate burst.
        rate = bytesPerSecond; tokens = 0; lastRefill = clock.now(); pump()
    }
    public func acquire(bytes: Int) async throws {
        try Task.checkCancellation()
        guard (0...Self.maximumAdmissionBytes).contains(bytes) else { throw StorageFailure.invalidRange }
        guard bytes > 0, rate > 0 else { return }
        guard queue.count < 128 else { throw StorageFailure.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Waiter(id: id, bytes: bytes, continuation: continuation)); pump()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
    }
    private func cancel(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError()); pump()
    }
    private func pump() {
        timer?.cancel(); timer = nil; timerGeneration &+= 1
        let now = clock.now(), elapsed = max(0, now - lastRefill); lastRefill = now
        tokens = min(Double(Self.maximumAdmissionBytes), tokens + elapsed * Double(rate))
        while let first = queue.first, rate == 0 || tokens >= Double(first.bytes) {
            if rate > 0 { tokens -= Double(first.bytes) }
            queue.removeFirst().continuation.resume()
        }
        guard let first = queue.first else { return }
        let wait = max(0.000_001, (Double(first.bytes) - tokens) / Double(rate)), generation = timerGeneration
        timer = Task { [clock] in
            do { try await clock.sleep(seconds: wait); self.timerFired(generation) }
            catch { /* Cancellation retires an obsolete timer, never a caller. */ }
        }
    }
    private func timerFired(_ generation: UInt64) {
        guard generation == timerGeneration else { return }; pump()
    }
}

/// Reads, HEAD, listings and provider-side copies are not charged to upload rate.
/// Upload readers and PUT bodies share exactly one limiter across all sync lanes.
public struct BandwidthLimitedStorageRemote: StorageRemote {
    private let base: any StorageRemote
    public let limiter: UploadBandwidthLimiter
    public init(base: any StorageRemote, limiter: UploadBandwidthLimiter) { self.base = base; self.limiter = limiter }
    public func qualifyConditionalDelete() async throws {
        if let native = base as? S3StorageRemote { try await native.qualifyConditionalDelete() }
        else if let wrapped = base as? BandwidthLimitedStorageRemote { try await wrapped.qualifyConditionalDelete() }
        else { guard base is FixtureStorageRemote else { throw StorageFailure.unsupported } }
    }
    public func head(key: String) async throws -> StorageObject? { try await base.head(key: key) }
    public func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange { try await base.read(key: key, range: range, validator: validator) }
    public func readContentAddressed(key: String, maximum: Int, checksum: String) async throws -> Data {
        try await base.readContentAddressed(key: key, maximum: maximum, checksum: checksum)
    }
    public func putContentAddressed(key: String, data: Data, operationID: UUID) async throws {
        try await limiter.acquire(bytes: data.count)
        try await base.putContentAddressed(key: key, data: data, operationID: operationID)
    }
    public func list(prefix: String, cursor: String?, limit: Int) async throws -> StoragePage { try await base.list(prefix: prefix, cursor: cursor, limit: limit) }
    public func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) async throws -> StorageObject { try await base.copy(source: source, destination: destination, sourceValidator: sourceValidator, operationID: operationID) }
    public func removeWritebackObject(_ object: StorageObject, id: UUID, checksum: String) async throws {
        try await base.removeWritebackObject(object, id: id, checksum: checksum)
    }
    public func delete(key: String, validator: String) async throws { try await base.delete(key: key, validator: validator) }
    public func setModifiedAt(key: String, validator: String, date: Date, operationID: UUID) async throws -> StorageObject { try await base.setModifiedAt(key: key, validator: validator, date: date, operationID: operationID) }
    public func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject {
        try await limiter.acquire(bytes: data.count)
        return try await base.put(key: key, data: data, condition: condition, operationID: operationID)
    }
    public func upload(key: String, size: Int64, condition: StorageCondition, operationID: UUID, reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        try await base.upload(key: key, size: size, condition: condition, operationID: operationID, reader: limited(reader))
    }
    public func uploadContent(keyHint: String, size: Int64, operationID: UUID, reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        try await base.uploadContent(keyHint: keyHint, size: size, operationID: operationID, reader: limited(reader))
    }
    private func limited(_ reader: @escaping @Sendable (Range<Int64>) async throws -> Data) -> @Sendable (Range<Int64>) async throws -> Data {
        { [limiter] range in
            try await limiter.acquire(bytes: range.count)
            return try await reader(range)
        }
    }
}
