import Foundation

/// Admission for immutable payload preparation only. Publication stays with the
/// journal's single ordered publisher. File reservations account for each file's
/// next reader range; the transport separately caps simultaneous multipart parts.
/// Neither allowance is a claim about total URLSession/Foundation allocation.
struct ManagedUploadSchedule {
    enum Lane: Sendable { case small, large }
    struct Admission: Sendable {
        let index: Int
        let lane: Lane
        let readerBytes: Int64
    }
    static let smallFileLimit: Int64 = 8 * 1024 * 1024
    private let maximumFiles: Int
    private let maximumReaderBytes: Int64
    private var small: [Admission] = []
    private var large: [Admission] = []
    private var active: [Int: Admission] = [:]
    private var preferSmall = true

    init(sizes: [Int64], maximumFiles: Int, maximumReaderBytes: Int64 = 256 * 1024 * 1024) {
        self.maximumFiles = min(8, max(1, maximumFiles))
        // One maximum-size native reader must always be able to enter.
        self.maximumReaderBytes = max(64 * 1024 * 1024, maximumReaderBytes)
        for (index, rawSize) in sizes.enumerated() {
            let size = max(0, rawSize), lane: Lane = size <= Self.smallFileLimit ? .small : .large
            // Native single PUTs use at most 8 MiB; multipart readers use 16–64
            // MiB. Reserve that request's bound across all admitted file jobs.
            let minimumPart = size / 9999 + (size % 9999 == 0 ? 0 : 1)
            let mib: Int64 = 1024 * 1024
            let roundedPart = ((minimumPart + mib - 1) / mib) * mib
            let part = min(64 * mib, max(16 * mib, roundedPart))
            let admission = Admission(index: index, lane: lane, readerBytes: min(size, lane == .small ? Self.smallFileLimit : part))
            if lane == .small { small.append(admission) } else { large.append(admission) }
        }
    }

    mutating func next() -> Admission? {
        guard active.count < maximumFiles else { return nil }
        let smallActive = active.values.filter { $0.lane == .small }.count
        let largeActive = active.count - smallActive
        let reserved = active.values.reduce(Int64(0)) { $0 + $1.readerBytes }
        // Mixed workloads reserve independent lanes. A class may borrow all
        // slots once the other class has neither queued nor active work.
        let smallLimit = large.isEmpty && largeActive == 0 ? maximumFiles : min(6, maximumFiles)
        let largeLimit = small.isEmpty && smallActive == 0 ? maximumFiles : min(4, maximumFiles)
        let canSmall = small.first.map { smallActive < smallLimit && $0.readerBytes <= maximumReaderBytes - reserved } ?? false
        let canLarge = large.first.map { largeActive < largeLimit && $0.readerBytes <= maximumReaderBytes - reserved } ?? false
        guard canSmall || canLarge else { return nil }
        let chooseSmall = canSmall && (!canLarge || preferSmall)
        let admission = chooseSmall ? small.removeFirst() : large.removeFirst()
        preferSmall = !chooseSmall
        active[admission.index] = admission
        return admission
    }

    mutating func complete(_ admission: Admission) { active.removeValue(forKey: admission.index) }
}

enum ManagedUploadPipeline {
    /// Refill each completed slot without waiting for the slowest file in a
    /// fixed window. Failed or paused work stops new admission; admitted tasks
    /// settle their own durable receipts before returning to the publisher.
    static func run<Value: Sendable>(sizes: [Int64], maximumFiles: Int,
                                     shouldContinue: @escaping @Sendable () async -> Bool,
                                     prepare: @escaping @Sendable (Int) async throws -> Value) async -> [Int: Result<Value, Error>] {
        await withTaskGroup(of: (ManagedUploadSchedule.Admission, Result<Value, Error>).self) { group in
            var schedule = ManagedUploadSchedule(sizes: sizes, maximumFiles: maximumFiles)
            var results: [Int: Result<Value, Error>] = [:]
            var admitting = await shouldContinue()
            func start(_ admission: ManagedUploadSchedule.Admission) {
                group.addTask {
                    do { return (admission, .success(try await prepare(admission.index))) }
                    catch { return (admission, .failure(error)) }
                }
            }
            while admitting, let admission = schedule.next() { start(admission) }
            while let (admission, result) = await group.next() {
                schedule.complete(admission); results[admission.index] = result
                if case .failure = result { admitting = false }
                if admitting { admitting = await shouldContinue() }
                while admitting, let next = schedule.next() { start(next) }
            }
            return results
        }
    }
}
