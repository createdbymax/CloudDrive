import SwiftUI
import Charts
import Darwin

/// One status poll. `bytesPerSecond == nil` means the engine did not answer,
/// which is shown as a gap rather than as a misleading 0.
struct UploadSpeedSample: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let bytesPerSecond: Double?
    let pending: Int
    /// Mac-wide outbound traffic measured by the OS, independent of the engine's own counter.
    var networkOutBytesPerSecond: Double? = nil
}

/// Reads per-interface byte counters from the OS. These counters are 32-bit, so
/// each delta is taken modulo 2^32 per interface.
final class NetworkOutSampler {
    private var last: [String: UInt32] = [:]
    private var lastTime: Date?

    static func counters() -> [String: UInt32] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: UInt32] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0, let data = entry.pointee.ifa_data {
                result[String(cString: entry.pointee.ifa_name)] = data.assumingMemoryBound(to: if_data.self).pointee.ifi_obytes
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }
    /// Bytes per second since the previous call; nil on the first call.
    func sample(now: Date = Date()) -> Double? {
        let current = Self.counters()
        defer { last = current; lastTime = now }
        guard let lastTime, now > lastTime else { return nil }
        var delta: UInt64 = 0
        for (name, value) in current { if let old = last[name] { delta += UInt64(value &- old) } }
        return Double(delta) / now.timeIntervalSince(lastTime)
    }
}

/// Bounded in-memory history for troubleshooting stalls.
struct UploadSpeedHistory: Equatable {
    static let retention: TimeInterval = 3600
    private(set) var samples: [UploadSpeedSample] = []

    mutating func record(bytesPerSecond: Double?, pending: Int, networkOut: Double? = nil, at time: Date = Date()) {
        func valid(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        samples.append(UploadSpeedSample(time: time, bytesPerSecond: valid(bytesPerSecond), pending: pending, networkOutBytesPerSecond: valid(networkOut)))
        let cutoff = time.addingTimeInterval(-Self.retention)
        if let first = samples.firstIndex(where: { $0.time >= cutoff }), first > 0 { samples.removeFirst(first) }
    }
    mutating func reset() { samples.removeAll() }

    func window(_ seconds: TimeInterval, now: Date) -> [UploadSpeedSample] {
        samples.filter { $0.time >= now.addingTimeInterval(-seconds) }
    }
    /// Seconds in the window where the engine answered but reported (almost) no upload traffic.
    func stalledSeconds(in window: [UploadSpeedSample]) -> TimeInterval {
        var total: TimeInterval = 0
        for (a, b) in zip(window, window.dropFirst()) {
            if let rate = a.bytesPerSecond, rate < 1024 { total += b.time.timeIntervalSince(a.time) }
        }
        return total
    }
}

struct UploadSpeedHistoryView: View {
    let history: UploadSpeedHistory
    @State private var windowSeconds: TimeInterval = 300

    private static let windows: [(String, TimeInterval)] = [("1 min", 60), ("5 min", 300), ("15 min", 900), ("1 hr", 3600)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let data = history.window(windowSeconds, now: now)
            let rates = data.compactMap(\.bytesPerSecond)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Upload speed history").font(.headline)
                    Spacer()
                    Picker("Window", selection: $windowSeconds) {
                        ForEach(Self.windows, id: \.1) { Text($0.0).tag($0.1) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
                }
                if data.count < 2 {
                    Text("Collecting samples…").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    Chart {
                        ForEach(data) { sample in
                            if let net = sample.networkOutBytesPerSecond {
                                LineMark(x: .value("Time", sample.time), y: .value("MB/s", net / 1_000_000), series: .value("Source", "Mac network out"))
                                    .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                            if let rate = sample.bytesPerSecond {
                                AreaMark(x: .value("Time", sample.time), y: .value("MB/s", rate / 1_000_000))
                                    .foregroundStyle(Color.accentColor.opacity(0.15))
                                LineMark(x: .value("Time", sample.time), y: .value("MB/s", rate / 1_000_000))
                                    .foregroundStyle(Color.accentColor)
                                    .interpolationMethod(.monotone)
                            } else {
                                // No answer from the engine: mark it so outages are visible.
                                RuleMark(x: .value("Time", sample.time)).foregroundStyle(Color.orange.opacity(0.5))
                            }
                        }
                    }
                    .chartXScale(domain: now.addingTimeInterval(-windowSeconds)...now)
                    .chartYAxisLabel("MB/s")
                    .chartYScale(domain: 0...max(1, max(rates.max() ?? 0, data.compactMap(\.networkOutBytesPerSecond).max() ?? 0) / 1_000_000 * 1.15))
                    .frame(height: 160)
                    .accessibilityLabel("Upload speed over the last \(Int(windowSeconds / 60)) minutes")
                    .accessibilityValue(summary(rates, data))
                    Text("Solid line: speed reported by the sync engine. Dashed: all outbound traffic on this Mac. If dashed is high while solid is 0, uploads are running but the engine's meter is wrong; if both are 0, nothing is being sent.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(summary(rates, data)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func summary(_ rates: [Double], _ data: [UploadSpeedSample]) -> String {
        guard !rates.isEmpty else { return "No status samples" }
        let avg = rates.reduce(0, +) / Double(rates.count)
        let stalled = history.stalledSeconds(in: data)
        let missing = data.filter { $0.bytesPerSecond == nil }.count
        var text = "Now \(UploadMetricText.speed(rates.last)) · avg \(UploadMetricText.speed(avg)) · peak \(UploadMetricText.speed(rates.max())) · stalled \(Int(stalled))s"
        if missing > 0 { text += " · \(missing) missed polls" }
        return text
    }
}
