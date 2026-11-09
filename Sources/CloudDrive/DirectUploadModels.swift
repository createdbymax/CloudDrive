import Foundation
import CryptoKit
import Darwin

enum DirectUploadFailure: LocalizedError, Equatable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum DirectUploadStatus: String, Codable, Sendable {
    case waiting, uploading, paused, checking, uploaded, attention, cancelling, cancelled
    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .uploading: return "Uploading"
        case .paused: return "Paused · progress saved"
        case .checking: return "Checking upload"
        case .uploaded: return "Uploaded"
        case .attention: return "Needs attention"
        case .cancelling: return "Cancelling"
        case .cancelled: return "Cancelled"
        }
    }
}

enum DirectUploadPhase: String, Codable, Sendable { case queued, initiating, transferring, completing, complete }

struct UploadSourceIdentity: Codable, Equatable, Sendable {
    let volume: String
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    static func capture(_ url: URL) throws -> Self {
        try requireResident(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw DirectUploadFailure.message("The source drive is unavailable or this file cannot be opened. Reconnect the original drive and retry.") }
        defer { close(fd) }
        return try capture(fd: fd, url: url)
    }

    static func requireResident(_ url: URL) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
              s.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw DirectUploadFailure.message("The source is unavailable, not a regular file, or is a cloud placeholder. Choose a resident original on a local or external drive.")
        }
    }

    static func capture(fd: Int32, url: URL) throws -> Self {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size >= 0,
              s.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw DirectUploadFailure.message("Only resident regular files can be uploaded directly.")
        }
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .isUbiquitousItemKey, .volumeIsLocalKey])
        guard values.isUbiquitousItem != true, values.volumeIsLocal == true else {
            throw DirectUploadFailure.message("Cloud placeholder files are not supported. Choose resident files on a local or external drive.")
        }
        guard let volume = values.volumeUUIDString, !volume.isEmpty else {
            throw DirectUploadFailure.message("This volume has no stable identity. Direct upload requires an identifiable local or external volume.")
        }
        return Self(volume: volume, inode: UInt64(s.st_ino), size: Int64(s.st_size),
                    modifiedSeconds: Int64(s.st_mtimespec.tv_sec), modifiedNanos: Int64(s.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(s.st_ctimespec.tv_sec), changedNanos: Int64(s.st_ctimespec.tv_nsec))
    }
}

struct ConfirmedUploadPart: Codable, Equatable, Sendable {
    let number: Int
    let etag: String
    let md5: String
    let size: Int64
}

struct DirectUploadJob: Codable, Identifiable, Sendable {
    var version = 1
    var id = UUID()
    var batchID: UUID
    var sourcePath: String
    var bookmark: Data?
    var source: UploadSourceIdentity
    var destination: String
    var key: String
    var partSize: Int64
    var uploadID: String?
    // Optional for backwards-compatible decoding of existing multipart queues.
    var singlePutMD5: String?
    var createdAt = Date()
    var uploadCreatedAt: Date?
    var status: DirectUploadStatus = .waiting
    var phase: DirectUploadPhase = .queued
    var message = ""
    var parts: [ConfirmedUploadPart] = []
    var verifiedAt: Date?

    var name: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
    var completedBytes: Int64 { status == .uploaded ? source.size : parts.reduce(0) { $0 + $1.size } }
    var partCount: Int { source.size == 0 ? 0 : Int((source.size + partSize - 1) / partSize) }
    var progress: Double { source.size == 0 ? (status == .uploaded ? 1 : 0) : min(1, Double(completedBytes) / Double(source.size)) }
    var terminal: Bool { status == .uploaded || status == .cancelled }

    static func partSize(for size: Int64) throws -> Int64 {
        guard size >= 0, size <= 5 * 1_099_511_627_776 else { throw DirectUploadFailure.message("R2 supports objects up to 5 TiB.") }
        // Fixed for the lifetime of an upload. 400 GB fits in fewer than 6,400 parts.
        let mib: Int64 = 1_048_576
        // 16 MiB parts keep many requests in flight, make progress move smoothly and
        // bound the cost of a retried part. Very large files grow the part to stay under 10,000.
        return max(16 * mib, ((size + 9_999) / 10_000 + mib - 1) / mib * mib)
    }

    var expectedETag: String? {
        if let singlePutMD5 { return singlePutMD5 }
        if source.size == 0 { return Insecure.MD5.hash(data: Data()).hex }
        guard parts.count == partCount, Set(parts.map(\.number)) == Set(1...partCount) else { return nil }
        var hashes = Data()
        for part in parts.sorted(by: { $0.number < $1.number }) {
            guard let binary = Data(hex: part.md5), binary.count == 16 else { return nil }
            hashes.append(binary)
        }
        return Insecure.MD5.hash(data: hashes).hex + "-\(partCount)"
    }

    func validate() throws {
        let maximum = 5 * Int64(1_099_511_627_776)
        guard version == 1, source.size >= 0, source.size <= maximum,
              partSize >= 5 * 1_048_576, partSize <= 1024 * 1_048_576,
              partCount <= 10_000, sourcePath.hasPrefix("/"), !sourcePath.contains("\0"),
              key.utf8.count <= 1024, !key.isEmpty, !key.hasPrefix("/"),
              !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              destination.count == 64, Data(hex: destination)?.count == 32,
              uploadID == nil || (!(uploadID?.isEmpty ?? true) && (uploadID?.utf8.count ?? 0) <= 4096),
              parts.count <= partCount, Set(parts.map(\.number)).count == parts.count else {
            throw DirectUploadFailure.message("Upload records are invalid. They were preserved for recovery.")
        }
        if let digest = singlePutMD5 {
            guard source.size > 0, source.size <= 8 * 1_048_576, Data(hex: digest)?.count == 16,
                  uploadID == nil, parts.isEmpty, phase == .completing || phase == .complete else {
                throw DirectUploadFailure.message("The saved single-request upload intent is invalid. Records were preserved.")
            }
        }
        for part in parts {
            guard part.number > 0, part.number <= partCount,
                  part.size == min(partSize, source.size - Int64(part.number - 1) * partSize),
                  Data(hex: part.md5)?.count == 16, part.etag == part.md5 else {
                throw DirectUploadFailure.message("A saved part checksum or size is invalid. Upload records were preserved.")
            }
        }
        guard status != .uploaded || (verifiedAt != nil && expectedETag != nil) else {
            throw DirectUploadFailure.message("The saved upload receipt is incomplete.")
        }
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte); index = next
        }
    }
}
