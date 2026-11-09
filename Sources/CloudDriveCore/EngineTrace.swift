import Foundation

/// Lightweight phase timing for diagnosing upload stalls. Writes only phases
/// slower than `threshold` to a size-bounded private log; never affects behaviour.
public enum EngineTrace {
    static let threshold: Duration = .milliseconds(150)
    private static let lock = NSLock()
    private static let url: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BucketDrive", isDirectory: true)
        return base.appendingPathComponent("engine-trace.log")
    }()

    public static func measure<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        defer { record(name, clock.now - start) }
        return try await body()
    }
    private static var totals: [String: (count: Int, ms: Int)] = [:]
    private static var lastFlush = Date()
    static func record(_ name: String, _ elapsed: Duration) {
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let key = name.replacingOccurrences(of: "\\(\\d+\\)", with: "(n)", options: .regularExpression)
        lock.lock()
        var entry = totals[key] ?? (0, 0); entry.count += 1; entry.ms += ms; totals[key] = entry
        var summary = ""
        if Date().timeIntervalSince(lastFlush) >= 30 {
            lastFlush = Date()
            let stamp = ISO8601DateFormatter().string(from: Date())
            for (k, v) in totals.sorted(by: { $0.value.ms > $1.value.ms }) { summary += "\(stamp) AGG \(k) n=\(v.count) total=\(v.ms)ms\n" }
            totals.removeAll()
        }
        lock.unlock()
        if !summary.isEmpty { append(summary) }
        guard elapsed >= threshold else { return }
        append("\(ISO8601DateFormatter().string(from: Date())) \(name) \(ms)ms\n")
    }
    private static func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 4_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8))
        } else { FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600]) }
    }
}
