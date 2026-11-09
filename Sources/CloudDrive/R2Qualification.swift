import Foundation
import Combine
import CryptoKit
import Darwin
import CloudDriveCore

protocol R2QualificationRemote: StorageRemote {
    func qualifyConditionalDelete() async throws
}
extension S3StorageRemote: R2QualificationRemote {}

struct R2QualificationReport: Codable, Sendable {
    struct Step: Codable, Sendable { var name: String; var state: String; var diagnostic: String? }
    var version = 1
    var runID: UUID
    var startedAt = Date()
    var finishedAt: Date?
    var state = "running"
    var steps: [Step] = []
    var retainedObjects: [String] = []
    var verifiedSHA256: [String: String] = [:]
    var payloadBytes: Int64 = 17 * 1024 * 1024
    var scope = "Isolated synthetic objects only; no Finder, power-loss, external-writer or general release qualification."
}

/// A serial, bounded scenario. It never lists or deletes the connection's parent
/// prefix. An unknown outcome leaves the whole generated fixture for inspection.
actor R2QualificationScenario {
    private let remote: any R2QualificationRemote
    private let prefix: String
    private let checkpoint: @Sendable (R2QualificationReport) async throws -> Void
    private var report: R2QualificationReport
    private var known: [String: StorageObject] = [:]
    private var source: StorageObject?
    private var incomplete = false
    static let multipartSize: Int64 = 17 * 1024 * 1024
    init(remote: any R2QualificationRemote, prefix: String, runID: UUID,
         checkpoint: @escaping @Sendable (R2QualificationReport) async throws -> Void) {
        self.remote = remote; self.prefix = prefix; report = .init(runID: runID); self.checkpoint = checkpoint
    }
    static func diagnostic(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        switch error as? StorageFailure {
        case .conflict: return "precondition-conflict"
        case .fileTooLarge: return "file-too-large"
        case .unknownOutcome: return "unknown-outcome"
        case .unsupported: return "unsupported-operation"
        case .offline: return "network-unavailable"
        case .invalidRange: return "invalid-range"
        case .integrity: return "integrity-check-failed"
        case .notFound: return "expected-object-missing"
        case .localStorageFull: return "local-storage-full"
        case .busy: return "busy"
        case .invalidResponse: return "invalid-provider-response"
        case nil: return "local-or-transport-error"
        }
    }
    /// Range-repeatable pattern; at most 16 MiB allocated by any reader request.
    static func payload(_ range: Range<Int64>, salt: UInt8 = 0) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= multipartSize, range.count <= 16 * 1024 * 1024 else { throw StorageFailure.invalidRange }
        var data = Data(); data.reserveCapacity(Int(range.count)); var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(range.upperBound, (offset / 65_536 + 1) * 65_536)
            data.append(Data(repeating: UInt8((offset / 65_536) % 251) &+ salt, count: Int(end - offset))); offset = end
        }
        return data
    }
    private func remember(_ object: StorageObject, operationID: UUID, size: Int64) throws {
        guard object.key.hasPrefix(prefix + "/"), object.operationID == operationID, object.size == size,
              !object.validator.isEmpty else { throw StorageFailure.integrity }
        known[object.key] = object
        report.retainedObjects = known.keys.sorted().map { String($0.dropFirst(prefix.count + 1)) }
    }
    private func unchanged(_ object: StorageObject) async throws {
        guard let current = try await remote.head(key: object.key), current.validator == object.validator,
              current.operationID == object.operationID, current.size == object.size,
              current.checksum == object.checksum else { throw StorageFailure.integrity }
    }
    private func expectConflict(_ operation: @Sendable () async throws -> Void) async throws {
        do { try await operation(); throw StorageFailure.integrity }
        catch StorageFailure.conflict { return }
    }
    private func verifyBytes(_ object: StorageObject, salt: UInt8) async throws {
        var actual = SHA256(), expected = SHA256(), offset: Int64 = 0
        while offset < object.size {
            try Task.checkCancellation()
            let range = offset..<min(object.size, offset + 1024 * 1024)
            let response = try await remote.read(key: object.key, range: range, validator: object.validator)
            guard response.offset == offset, response.totalSize == object.size, response.validator == object.validator,
                  response.data.count == range.count else { throw StorageFailure.invalidRange }
            actual.update(data: response.data); expected.update(data: try Self.payload(range, salt: salt)); offset = range.upperBound
        }
        let actualDigest = actual.finalize()
        guard actualDigest == expected.finalize() else { throw StorageFailure.integrity }
        report.verifiedSHA256[String(object.key.dropFirst(prefix.count + 1))] = actualDigest.map { String(format: "%02x", $0) }.joined()
    }
    private func perform(_ name: String) async throws {
        switch name {
        case "conditional-put":
            let key = prefix + "/small.bin", size: Int64 = 128 * 1024, id = UUID()
            let original = try await remote.put(key: key, data: Self.payload(0..<size), condition: .absent, operationID: id)
            try remember(original, operationID: id, size: size)
            try await checkpoint(report)
            let remote = self.remote
            try await expectConflict { _ = try await remote.put(key: key, data: Data("must-not-replace".utf8), condition: .absent, operationID: UUID()) }
            try await unchanged(original)
            try await expectConflict { _ = try await remote.put(key: key, data: Data("must-not-replace".utf8), condition: .matches("\"wrong-" + UUID().uuidString + "\""), operationID: UUID()) }
            try await unchanged(original)
            let replacementID = UUID()
            let replaced = try await remote.put(key: key, data: Self.payload(0..<size, salt: 19), condition: .matches(original.validator), operationID: replacementID)
            try remember(replaced, operationID: replacementID, size: size); source = replaced
        case "range-and-list":
            guard let source else { throw StorageFailure.integrity }
            try await verifyBytes(source, salt: 19)
            let page = try await remote.list(prefix: prefix + "/", cursor: nil, limit: 100)
            guard page.nextCursor == nil, page.objects.contains(where: { $0.key == source.key && $0.validator == source.validator && $0.size == source.size }),
                  page.objects.allSatisfy({ $0.key.hasPrefix(prefix + "/") }) else { throw StorageFailure.integrity }
        case "conditional-copy":
            guard let source else { throw StorageFailure.integrity }
            let id = UUID(), key = prefix + "/copied.bin"
            let copy = try await remote.copy(source: source.key, destination: key, sourceValidator: source.validator, operationID: id)
            try remember(copy, operationID: id, size: source.size)
            try await verifyBytes(copy, salt: 19)
        case "conditional-delete-capability":
            try await remote.qualifyConditionalDelete()
        case "multipart-and-full-readback":
            let id = UUID(), key = prefix + "/multipart.bin"
            let object = try await remote.upload(key: key, size: Self.multipartSize, condition: .absent, operationID: id) { try Self.payload($0, salt: 43) }
            try remember(object, operationID: id, size: Self.multipartSize)
            // Native ordinary-key upload publishes through this operation-owned
            // staging object. A fixture remote need not create a staging object.
            let stagingKey = prefix + "/.clouddrive/v1/staging/" + id.uuidString
            if let staging = try await remote.head(key: stagingKey) { try remember(staging, operationID: id, size: Self.multipartSize) }
            try await checkpoint(report)
            try await verifyBytes(object, salt: 43)
        case "cleanup":
            // Preflight every known receipt before deleting any. No prefix-wide
            // cleanup, guessed keys, unconditional deletion or error-path cleanup.
            for object in known.values { try await unchanged(object) }
            for key in known.keys.sorted() {
                try Task.checkCancellation()
                guard let object = known[key] else { throw StorageFailure.integrity }
                try await remote.delete(key: key, validator: object.validator)
                guard try await remote.head(key: key) == nil else { throw StorageFailure.integrity }
                known.removeValue(forKey: key)
                report.retainedObjects = known.keys.sorted().map { String($0.dropFirst(prefix.count + 1)) }
                try await checkpoint(report)
            }
        default: throw StorageFailure.unsupported
        }
    }
    func run() async -> R2QualificationReport {
        for name in ["conditional-put", "range-and-list", "conditional-copy", "conditional-delete-capability", "multipart-and-full-readback", "cleanup"] {
            if name == "cleanup" && incomplete {
                report.steps.append(.init(name: name, state: "retained", diagnostic: "incomplete-run-preserves-fixture")); break
            }
            report.steps.append(.init(name: name, state: "running"))
            do {
                try Task.checkCancellation(); try await checkpoint(report); try await perform(name)
                report.steps[report.steps.count - 1].state = "passed"; try await checkpoint(report)
            } catch {
                report.steps[report.steps.count - 1].state = "failed"
                report.steps[report.steps.count - 1].diagnostic = Self.diagnostic(error)
                if ["conditional-copy", "conditional-delete-capability"].contains(name), error as? StorageFailure == .unsupported {
                    incomplete = true; report.steps[report.steps.count - 1].state = "unsupported"
                } else {
                    report.state = "failed"; report.finishedAt = Date(); try? await checkpoint(report); return report
                }
            }
        }
        report.state = incomplete ? "incomplete" : "passed"; report.finishedAt = Date()
        do { try await checkpoint(report) } catch { report.state = "report-write-failed" }
        return report
    }
}

@MainActor final class R2QualificationController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = "Not run"
    @Published private(set) var reportURL: URL?
    @Published private(set) var result: R2QualificationReport?
    private func publish(_ report: R2QualificationReport) {
        result = report; progress = report.steps.last?.name ?? "Preparing isolated test"
    }
    func run(connection: Connection, root: URL) async {
        guard !isRunning else { return }
        isRunning = true; result = nil; reportURL = nil; progress = "Preparing isolated test"
        defer { isRunning = false }
        do {
            try connection.validate()
            let runID = UUID(), directory = root.appendingPathComponent("Qualifications").appendingPathComponent(runID.uuidString)
            try Self.privateDirectory(root.appendingPathComponent("Qualifications"))
            try Self.privateDirectory(directory)
            let reportPath = directory.appendingPathComponent("report.json")
            reportURL = reportPath
            let configuration = R2StorageConfiguration(endpoint: connection.endpoint, bucket: connection.bucket,
                prefix: connection.prefix + "/clouddrive-qualification-" + runID.uuidString.lowercased(), accessKey: connection.accessKey, secretKey: connection.secretKey)
            let remote = try S3StorageRemote(configuration: configuration, multipartDirectory: directory.appendingPathComponent("Multipart"))
            defer { remote.close() }
            let scenario = R2QualificationScenario(remote: remote, prefix: configuration.prefix, runID: runID) { [weak self] report in
                try Self.save(report, at: reportPath)
                await self?.publish(report)
            }
            let completed = await scenario.run(); result = completed
            progress = completed.state == "passed" ? "Passed; synthetic objects removed" : "Incomplete; test evidence and objects retained"
        } catch {
            progress = "Could not prepare test: " + R2QualificationScenario.diagnostic(error)
        }
    }
    nonisolated private static func privateDirectory(_ path: URL) throws {
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw StorageFailure.integrity }
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StorageFailure.integrity }
    }
    nonisolated private static func save(_ report: R2QualificationReport, at path: URL) throws {
        let temporary = path.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageFailure.integrity }
        defer { Darwin.close(descriptor); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: JSONEncoder().encode(report)); try handle.synchronize()
        guard Darwin.rename(temporary.path, path.path) == 0 else { throw StorageFailure.integrity }
        let parent = Darwin.open(path.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw StorageFailure.integrity }; defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw StorageFailure.integrity }
    }
}
