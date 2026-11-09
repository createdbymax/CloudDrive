import Foundation

enum DirectUploadConcurrency: Int, CaseIterable, Sendable, Identifiable {
    case one = 1, two = 2, four = 4, eight = 8
    var id: Int { rawValue }
    var label: String { "\(rawValue) \(self == .one ? "file" : "files")" }
}

/// Connection limits are decimal megabits/second, unlike observed transfer bytes/second.
enum UploadLimit: Int, CaseIterable, Codable, Sendable, Identifiable {
    case unlimited = 0, mbps5 = 5, mbps10 = 10, mbps20 = 20, mbps50 = 50
    var id: Int { rawValue }
    var label: String { self == .unlimited ? "Unlimited" : "\(rawValue) Mbps" }
    var bytesPerSecond: Int64 { self == .unlimited ? -1 : Int64(rawValue) * 1_000_000 / 8 }
    static func namespaceLabel(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond, bytesPerSecond >= 0 else { return "Unknown" }
        if let preset = allCases.first(where: { max(0, $0.bytesPerSecond) == bytesPerSecond }) { return preset.label }
        return "\(bytesPerSecond.formatted()) B/s"
    }
    /// Bare rclone numbers mean KiB/s. Explicit B preserves the decimal conversion.
    var controlRate: String { self == .unlimited ? "off" : "\(bytesPerSecond)B:off" }
}

struct BandwidthStatus: Decodable, Equatable, Sendable {
    let bytesPerSecondTx: Int64
    let bytesPerSecondRx: Int64
    private enum CodingKeys: String, CodingKey { case bytesPerSecondTx, bytesPerSecondRx }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytesPerSecondTx = try c.decode(Int64.self, forKey: .bytesPerSecondTx)
        bytesPerSecondRx = try c.decode(Int64.self, forKey: .bytesPerSecondRx)
        guard bytesPerSecondTx == -1 || bytesPerSecondTx > 0,
              bytesPerSecondRx == -1 else { throw RuntimeFailure.invalidControlResponse }
    }
    static func decode(_ data: Data) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RuntimeFailure.invalidControlResponse }
    }
    var uploadLimit: UploadLimit? { UploadLimit.allCases.first { $0.bytesPerSecond == bytesPerSecondTx } }
}

extension ControlClient {
    func uploadLimit() async throws -> UploadLimit {
        let status = try BandwidthStatus.decode(await call(route: "core/bwlimit"))
        guard let limit = status.uploadLimit else { throw RuntimeFailure.invalidControlResponse }
        return limit
    }
    /// Both mutation response and independent readback must match. A failed readback
    /// leaves the result uncertain; callers must not display the requested value as applied.
    @discardableResult func setUploadLimit(_ limit: UploadLimit) async throws -> UploadLimit {
        let body = try JSONSerialization.data(withJSONObject: ["rate":limit.controlRate])
        let response = try BandwidthStatus.decode(await call(route: "core/bwlimit", body: body))
        guard response.uploadLimit == limit else { throw RuntimeFailure.invalidControlResponse }
        let readback = try await uploadLimit()
        guard readback == limit else { throw RuntimeFailure.invalidControlResponse }
        return readback
    }
    /// Caller must authenticate worker ownership and re-fetch the exact ID/name/size
    /// immediately before this call. IDs are not valid across worker restarts. This
    /// schedules a waiting item; it is neither completion nor an active-transfer pause.
    func requestUploadRetry(_ item: UploadItem, fs: String) async throws {
        guard !fs.isEmpty, item.id >= 0, !item.name.isEmpty, item.size >= 0, !item.uploading else {
            throw RuntimeFailure.invalidControlResponse
        }
        let body = try JSONSerialization.data(withJSONObject: ["fs":fs, "id":item.id, "expiry":-1_000_000_000] as [String:Any])
        let data = try await call(route: "vfs/queue-set-expiry", body: body)
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String:Any], result.isEmpty else {
            throw RuntimeFailure.invalidControlResponse
        }
    }
}
