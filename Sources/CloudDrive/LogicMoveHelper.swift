#if DEBUG
import Foundation
import CloudDriveCore
import Darwin

/// One noninteractive, saved-connection operation scoped to the approved folder pair.
enum LogicMoveHelper {
    struct Request: Codable {
        let op: String
        let binding: String
        let relativePath: String
        var destinationRelativePath: String?
        var side: String?
        var sourceValidator: String?
        var sourceSize: Int64?
        var operationID: UUID?
    }
    struct Reply: Codable {
        var ok: Bool
        var exists: Bool?
        var validator: String?
        var size: Int64?
        var operationID: UUID?
        var error: String?
        init(object: StorageObject?) {
            ok = true; exists = object != nil
            validator = object?.validator; size = object?.size; operationID = object?.operationID
        }
        init(error: String) { ok = false; self.error = error }
    }
    enum Failure: String, Error {
        case invalidRequest, unsafePath, wrongBinding, missingQualification, changedSource
    }
    static func keys(_ request: Request, prefix: String) throws -> (source: String, destination: String) {
        func components(_ value: String) throws -> [Substring] {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard !value.isEmpty, !value.contains("\\"), value.rangeOfCharacter(from: .controlCharacters) == nil,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".clouddrive" }) else {
                throw Failure.unsafePath
            }
            return parts
        }
        let destination = request.destinationRelativePath ?? request.relativePath
        let a = try components(request.relativePath), b = try components(destination)
        guard a.count == b.count else { throw Failure.unsafePath }
        for (original, requested) in zip(a, b) where !original.utf8.elementsEqual(requested.utf8) {
            // A collision name changes only the suffix before the final extension.
            let extensionStart = original.lastIndex(of: ".").flatMap { $0 == original.startIndex ? nil : $0 } ?? original.endIndex
            let start = String(original[..<extensionStart]) + " (from Logic Projects "
            let end = ")" + String(original[extensionStart...])
            let bytes = Array(requested.utf8), prefixBytes = Array(start.utf8), suffixBytes = Array(end.utf8)
            guard bytes.starts(with: prefixBytes), bytes.suffix(suffixBytes.count).elementsEqual(suffixBytes),
                  bytes.count > prefixBytes.count + suffixBytes.count else { throw Failure.unsafePath }
            let digits = bytes[prefixBytes.count..<(bytes.count - suffixBytes.count)]
            guard digits.count <= 9, digits.first != 48, digits.allSatisfy({ (48...57).contains($0) }) else { throw Failure.unsafePath }
        }
        let source = prefix + "/Logic Projects/" + request.relativePath
        let target = prefix + "/T5 Backup/Logic Projects/" + destination
        guard source.utf8.count <= 1024, target.utf8.count <= 1024 else { throw Failure.unsafePath }
        return (source, target)
    }
    static func perform(_ request: Request, binding: String, scope: String, remote: any StorageRemote, qualified: Bool) async throws -> Reply {
        guard request.binding == binding else { throw Failure.wrongBinding }
        let pair = try keys(request, prefix: scope)
        if request.op == "head" {
            guard request.side == "source" || request.side == "destination" else { throw Failure.invalidRequest }
            return Reply(object: try await remote.head(key: request.side == "source" ? pair.source : pair.destination))
        }
        guard request.op == "copy", request.side == nil, let id = request.operationID,
              let size = request.sourceSize, size >= 0, let validator = request.sourceValidator,
              validator.range(of: #"^"[A-Fa-f0-9]+(-[1-9][0-9]*)?"$"#, options: .regularExpression) != nil,
              validator.utf8.count <= 256, validator.rangeOfCharacter(from: .controlCharacters) == nil else { throw Failure.invalidRequest }
        guard qualified else { throw Failure.missingQualification }
        guard size <= 5 * 1024 * 1024 * 1024 else { throw StorageFailure.unsupported }
        guard let original = try await remote.head(key: pair.source), original.size == size,
              original.validator == validator else { throw Failure.changedSource }
        let copied = try await remote.copy(source: pair.source, destination: pair.destination, sourceValidator: validator, operationID: id)
        guard copied.key.utf8.elementsEqual(pair.destination.utf8), copied.size == size, copied.operationID == id,
              !copied.validator.isEmpty else { throw StorageFailure.integrity }
        guard let source = try await remote.head(key: pair.source), source.validator == validator, source.size == size else { throw Failure.changedSource }
        return Reply(object: copied)
    }

    private struct Probe: Codable { let binding: String; let version: Int; let date: Date; let runID: UUID }
    private static func proofURL() throws -> URL {
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BucketDrive").appendingPathComponent("LogicMoveChecks")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.missingQualification }
        return parent.appendingPathComponent("copy-conditions-v1.json")
    }
    private static func qualified(_ binding: String) -> Bool {
        guard let path = try? proofURL() else { return false }
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 2048 else { return false }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try? file.read(upToCount: 2048), let proof = try? JSONDecoder().decode(Probe.self, from: bytes),
              proof.version == 1, proof.binding == binding else { return false }
        return (0..<86_400).contains(Date().timeIntervalSince(proof.date))
    }
    private static func check(connection: Connection, remote: S3StorageRemote, scope: String, id: UUID) async throws {
        try await remote.qualifyMoveCopyConditions()
        let relative = "probe.logicx/Audio Files/fixture #%.aif"
        var request = Request(op: "copy", binding: connection.fingerprint, relativePath: relative)
        let pair = try keys(request, prefix: scope)
        let data = Data("CloudDrive generated copy qualification".utf8)
        let source = try await remote.put(key: pair.source, data: data, condition: .absent, operationID: UUID())
        request.sourceSize = source.size; request.sourceValidator = source.validator; request.operationID = UUID()
        let first = try await perform(request, binding: connection.fingerprint, scope: scope, remote: remote, qualified: true)
        let repeated = try await perform(request, binding: connection.fingerprint, scope: scope, remote: remote, qualified: true)
        guard first.validator == repeated.validator, let tag = first.validator else { throw StorageFailure.integrity }
        let bytes = try await remote.read(key: pair.destination, range: 0..<Int64(data.count), validator: tag)
        guard bytes.data == data else { throw StorageFailure.integrity }
        let path = try proofURL()
        try JSONEncoder().encode(Probe(binding: connection.fingerprint, version: 1, date: Date(), runID: id)).write(to: path, options: .atomic)
        guard chmod(path.path, 0o600) == 0, qualified(connection.fingerprint) else { throw Failure.missingQualification }
    }
    private static func send(_ reply: Reply) throws {
        let bytes = try JSONEncoder().encode(reply)
        try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
    }
    private static func code(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.rawValue }
        return R2QualificationScenario.diagnostic(error)
    }
    static func run(probe: Bool) async -> Int32 {
        do {
            guard let connection = try await Credentials.loadBounded(allowInteraction: false) else {
                try send(Reply(error: "saved-connection-unavailable")); return 3
            }
            try connection.validate()
            let id = UUID()
            let scope = probe ? connection.prefix + "/clouddrive-move-qualification-" + id.uuidString.lowercased() : connection.prefix
            let configuration = R2StorageConfiguration(endpoint: connection.endpoint, bucket: connection.bucket, prefix: scope,
                accessKey: connection.accessKey, secretKey: connection.secretKey)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("clouddrive-move-" + UUID().uuidString)
            let remote = try S3StorageRemote(configuration: configuration, multipartDirectory: scratch)
            defer { remote.close(); try? FileManager.default.removeItem(at: scratch) }
            if probe {
                try await check(connection: connection, remote: remote, scope: scope, id: id)
                try send(Reply(object: nil)); return 0
            }
            var line = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Failure.invalidRequest }
                if count == 0 { guard line.isEmpty else { throw Failure.invalidRequest }; return 0 }
                for byte in buffer.prefix(count) {
                    if byte != 10 {
                        guard line.count < 16_384 else { throw Failure.invalidRequest }
                        line.append(byte); continue
                    }
                    do {
                        let request = try JSONDecoder().decode(Request.self, from: line)
                        let result = try await perform(request, binding: connection.fingerprint, scope: scope,
                            remote: remote, qualified: request.op == "copy" && qualified(connection.fingerprint))
                        try send(result)
                    } catch { try send(Reply(error: code(error))) }
                    line.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            try? send(Reply(error: code(error))); return 1
        }
    }
}
#endif
