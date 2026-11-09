import Foundation
import CryptoKit
import Darwin

/// Owns a source handle and its access scope. Each seek/read/check sequence is actor-atomic,
/// while completed reads can upload concurrently without sharing a mutable file position.
actor UploadSourceReader {
    private let source: UploadSourceIdentity
    private let partSize: Int64
    private let url: URL
    private var file: FileHandle?
    private var scoped: Bool

    init(job: DirectUploadJob) throws {
        guard job.source.size >= 0, job.source.size <= 5 * 1_099_511_627_776,
              job.partSize >= 5 * 1_048_576, job.partSize <= 1024 * 1_048_576 else {
            throw DirectUploadFailure.message("The saved source size or multipart size is invalid.")
        }
        var resolved = URL(fileURLWithPath: job.sourcePath)
        if let bookmark = job.bookmark {
            var stale = false
            resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let access = resolved.startAccessingSecurityScopedResource()
        var opened: FileHandle?
        do {
            try UploadSourceIdentity.requireResident(resolved)
            let fd = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else {
                throw DirectUploadFailure.message("Source drive disconnected or file unavailable. Reconnect the original drive and resume.")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            opened = handle
            guard try UploadSourceIdentity.capture(fd: fd, url: resolved) == job.source,
                  (try UploadSourceIdentity.capture(resolved)) == job.source else {
                throw Self.changedSource
            }
            source = job.source; partSize = job.partSize; url = resolved
            file = handle; scoped = access
        } catch {
            try? opened?.close()
            if access { resolved.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit {
        try? file?.close()
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    private static var changedSource: DirectUploadFailure {
        .message("The source file changed or this is a different drive. This upload cannot resume from the substituted contents.")
    }

    func validate() throws {
        guard let file else { throw DirectUploadFailure.message("The source reader has been closed. Reopen the original file to resume.") }
        guard try UploadSourceIdentity.capture(fd: file.fileDescriptor, url: url) == source,
              (try UploadSourceIdentity.capture(url)) == source else { throw Self.changedSource }
    }

    func readPart(number: Int) throws -> (Data, String) {
        guard number > 0, number <= 10_000, source.size > 0,
              Int64(number) <= (source.size + partSize - 1) / partSize else {
            throw DirectUploadFailure.message("The requested source part is outside this file.")
        }
        let offset = Int64(number - 1) * partSize
        return try read(offset: offset, count: Int(min(partSize, source.size - offset)))
    }

    func readWhole() throws -> (Data, String) {
        guard source.size > 0, source.size <= 8 * 1_048_576 else {
            throw DirectUploadFailure.message("Only files up to 8 MiB may use a single-request upload.")
        }
        return try read(offset: 0, count: Int(source.size))
    }

    private func read(offset: Int64, count: Int) throws -> (Data, String) {
        try Task.checkCancellation()
        try validate()
        guard let file else { throw DirectUploadFailure.message("The source reader is unavailable.") }
        // No await between seek and read: another part cannot change this handle's offset.
        try file.seek(toOffset: UInt64(offset))
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw DirectUploadFailure.message("The source drive stopped providing data. Reconnect it and resume.")
        }
        try validate()
        return (data, Insecure.MD5.hash(data: data).hex)
    }

    func uploadPart(number: Int, key: String, uploadID: String, remote: any MultipartRemote) async throws -> ConfirmedUploadPart {
        let (data, digest) = try readPart(number: number)
        let tag = try await remote.putPart(key: key, uploadID: uploadID, number: number, data: data, md5: digest)
        guard tag == digest else { throw MultipartRemoteError.checksumMismatch }
        // The caller receives only metadata; this scope owns the payload until the request returns.
        return ConfirmedUploadPart(number: number, etag: tag, md5: digest, size: Int64(data.count))
    }

    func close() {
        try? file?.close(); file = nil
        if scoped { url.stopAccessingSecurityScopedResource(); scoped = false }
    }
}
