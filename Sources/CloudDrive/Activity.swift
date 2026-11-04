import Foundation

struct UploadQueue: Decodable {
    let queue: [UploadItem]
    static func decode(_ data: Data) throws -> UploadQueue {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.queue.allSatisfy({ $0.id >= 0 && $0.size >= 0 && $0.tries >= 0 && !$0.name.isEmpty }) else { throw RuntimeFailure.invalidControlResponse }
        guard Set(result.queue.map(\.id)).count == result.queue.count,
              Set(result.queue.map(\.name)).count == result.queue.count else { throw RuntimeFailure.invalidControlResponse }
        return result
    }
}
struct UploadItem: Decodable, Identifiable {
    let id: Int64
    let name: String
    let size: Int64
    let tries: Int
    let uploading: Bool
    var label: String { uploading ? "Uploading" : tries > 1 ? "Retrying (\(tries) attempts)" : "Queued" }
}

struct DiagnosticEvent: Identifiable {
    let id = UUID()
    let time = Date()
    let category: String
    let outcome: String
}
