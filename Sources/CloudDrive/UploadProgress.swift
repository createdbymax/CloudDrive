import Foundation

/// Per-transfer counters from the pinned rclone core/stats response. Global lifetime
/// counters intentionally have no place in the upload presentation model.
struct TransferStats: Decodable {
    let transferring: [TransferCounter]
    private enum CodingKeys: String, CodingKey { case transferring, bytes, elapsedTime, speed, totalBytes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Require recognizable core/stats evidence even when rclone omits its idle array.
        let lifetimeBytes = try c.decode(Int64.self, forKey: .bytes)
        let elapsed = try c.decode(Double.self, forKey: .elapsedTime)
        let globalSpeed = try c.decodeIfPresent(Double.self, forKey: .speed)
        let total = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        guard lifetimeBytes >= 0, elapsed.isFinite, elapsed >= 0,
              globalSpeed.map({ $0.isFinite && $0 >= 0 }) ?? true, total.map({ $0 >= 0 }) ?? true else {
            throw RuntimeFailure.invalidControlResponse
        }
        // rclone omits transferring when there are no active transfers. Null is malformed.
        transferring = c.contains(.transferring) ? try c.decode([TransferCounter].self, forKey: .transferring) : []
    }
    static func decode(_ data: Data) throws -> TransferStats {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RuntimeFailure.invalidControlResponse }
    }
}

struct TransferCounter: Decodable {
    let name: String
    let size: Int64
    let bytes: Int64?
    let speed: Double?
    let speedAvg: Double?
    let eta: Double?
    let source: String?
    let destination: String?
    private enum CodingKeys: String, CodingKey {
        case name, size, bytes, speed, speedAvg, eta
        case source = "srcFs", destination = "dstFs"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(Int64.self, forKey: .size)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed)
        speedAvg = try c.decodeIfPresent(Double.self, forKey: .speedAvg)
        eta = try c.decodeIfPresent(Double.self, forKey: .eta)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        guard !name.isEmpty, size >= -1, bytes.map({ $0 >= 0 }) ?? true,
              [speed, speedAvg, eta].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }) else {
            throw RuntimeFailure.invalidControlResponse
        }
    }
}

struct UploadProgressRow: Identifiable, Equatable {
    let id: Int64
    let name: String
    let size: Int64?
    let bytes: Int64?
    /// Current smoothed transfer speed in bytes/second, never the lifetime global rate.
    let speed: Double?
    let eta: Double?
    /// nil means unknown. A full byte counter does not mean the file is committed.
    let progress: Double?
    let label: String
}

struct UploadProgressSnapshot: Equatable {
    let rows: [UploadProgressRow]
    let totalBytes: Int64?
    let completedBytes: Int64?
    let speed: Double?
    let eta: Double?
    let progress: Double?
    let queuedCount: Int
    let activeCount: Int
    let retryingCount: Int
    var isEmpty: Bool { rows.isEmpty }

    /// The outstanding VFS queue is authoritative. Exact name AND destination
    /// matching excludes cache downloads and unrelated transfers from upload metrics.
    static func make(queue: UploadQueue, stats: TransferStats, destination: String) -> UploadProgressSnapshot {
        let rows = queue.queue.map { item -> UploadProgressRow in
            let matches = stats.transferring.filter { $0.name == item.name && $0.destination == destination }
            let counter = matches.count == 1 ? matches[0] : nil
            var bytes: Int64?, speed: Double?, eta: Double?
            if !item.uploading {
                // Waiting retries aren't consuming upload bandwidth; their previous byte
                // progress remains unknown. Only a fresh first attempt is known to be zero.
                speed = 0
                if item.tries == 0 { bytes = 0 }
            } else if item.uploading, let counter,
                      counter.size == -1 || counter.size == item.size,
                      let count = counter.bytes, count <= item.size {
                bytes = count
                speed = counter.speedAvg ?? counter.speed
                eta = counter.eta
                // Null ETA is intentionally retained: no fabricated completion estimate.
            }
            let progress = bytes.flatMap { item.size > 0 ? Double($0) / Double(item.size) : nil }
            let label: String
            if item.uploading && bytes == item.size && item.size > 0 { label = "Finishing upload" }
            else { label = item.label }
            return UploadProgressRow(id: item.id, name: item.name, size: item.size,
                bytes: bytes, speed: speed, eta: eta, progress: progress, label: label)
        }
        let total = sum(rows.map(\.size))
        let done = sum(rows.map(\.bytes))
        let speeds = rows.map(\.speed)
        let rate: Double?
        if speeds.allSatisfy({ $0 != nil }) {
            let value = speeds.compactMap { $0 }.reduce(0, +)
            rate = value.isFinite ? value : nil
        } else { rate = nil }
        let progress = done.flatMap { done in total.flatMap { $0 > 0 ? Double(done) / Double($0) : nil } }
        let eta: Double?
        if let total, let done, let rate, rate > 0, done < total {
            let estimate = Double(total - done) / rate
            eta = estimate.isFinite ? estimate : nil
        } else { eta = nil }
        return UploadProgressSnapshot(rows: rows, totalBytes: total, completedBytes: done,
            speed: rate, eta: eta, progress: progress,
            queuedCount: queue.queue.filter { !$0.uploading }.count,
            activeCount: queue.queue.filter(\.uploading).count,
            retryingCount: queue.queue.filter { $0.tries > 1 }.count)
    }
    private static func sum(_ values: [Int64?]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard let value else { return nil }
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
