import Foundation
import CryptoKit
import Darwin

struct UploadQueueState: Sendable {
    let revision: UInt64
    let jobs: [DirectUploadJob]
}

actor DirectUploadEngine {
    private var store: UploadQueueStore?
    private var jobs: [DirectUploadJob] = []
    private var active = Set<UUID>()
    private var batching = false
    private var keyOwners: [String: UUID] = [:]
    private var publishing = false
    private var publicationPending = false
    private var revision: UInt64 = 0
    private var stateObserver: (@Sendable (UploadQueueState) async -> Void)?

    private struct Resources: Sendable {
        let memory: UploadMemoryBudget
        let rate: UploadRateLimiter
        let memoryLimit: Int64
    }

    private func resources(bytesPerSecond: Int64, jobs: [DirectUploadJob]) -> Resources {
        let limit = max(256 * Int64(1_048_576), jobs.map(\.partSize).max() ?? 0)
        return Resources(memory: UploadMemoryBudget(limit: limit), rate: UploadRateLimiter(bytesPerSecond: bytesPerSecond), memoryLimit: limit)
    }
    private var directory: URL?

    func open(directory: URL, recoverExisting: Bool = false, createParentDirectories: Bool = true) throws -> [DirectUploadJob] {
        guard active.isEmpty && !batching else { throw DirectUploadFailure.message("Pause the active upload before changing upload records.") }
        // Release the old lock only after its jobs have been saved. Reopening the same folder is harmless.
        if self.directory == directory, store != nil, !recoverExisting { return jobs }
        guard self.directory == directory || !jobs.contains(where: { !$0.terminal }) else { throw DirectUploadFailure.message("The current queue has unfinished uploads. Finish or cancel them before opening another records folder.") }
        if recoverExisting {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("uploads.sqlite").path) else {
                throw DirectUploadFailure.message("The selected folder has no saved upload database. Reconnect the records drive and choose its original CloudDrive Upload Records folder.")
            }
            if self.directory == directory { store = nil }
        }
        let next = try UploadQueueStore(directory: directory, createParentDirectories: createParentDirectories)
        var loaded = try next.load()
        try next.backfillCatalogHints(loaded)
        for i in loaded.indices where !loaded[i].terminal {
            if loaded[i].status == .uploading { loaded[i].status = .paused }
            if loaded[i].message.isEmpty { loaded[i].message = "Resume checks R2's saved parts before continuing." }
            try next.save(loaded[i])
        }
        store = next; self.directory = directory; jobs = loaded; revision &+= 1
        return loaded
    }

    func pendingCatalogHints(destination: String) throws -> [UploadCatalogHint] { try store?.pendingCatalogHints(destination:destination) ?? [] }
    func acknowledgeCatalogHints(_ hints: [UploadCatalogHint]) throws { try store?.acknowledgeCatalogHints(hints) }

    func snapshot() -> [DirectUploadJob] { jobs }
    func snapshotState() -> UploadQueueState { UploadQueueState(revision: revision, jobs: jobs) }
    func deliverLatest(update: @escaping @Sendable ([DirectUploadJob]) async -> Void) async { await publish(update) }

    func enqueue(urls: [URL], connection: Connection, excluded: [URL]) throws -> (jobs: [DirectUploadJob], skipped: Int) {
        guard let store, let directory else { throw DirectUploadFailure.message("Choose a writable upload records folder first.") }
        try connection.validate()
        guard !urls.isEmpty, urls.count <= 10_000 else { throw DirectUploadFailure.message("Choose between 1 and 10,000 items per batch.") }
        let batch = UUID()
        var additions: [DirectUploadJob] = [], skipped = 0, seen = Set(jobs.filter { !$0.terminal }.map(\.sourcePath))
        let excluded = (excluded + [directory]).map { (try? Self.canonicalURL($0).path) ?? $0.standardizedFileURL.path }
        let ignored: Set<String> = [".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems"]
        var roots: [URL] = []
        for original in urls.sorted(by: { $0.path.count < $1.path.count }) {
            guard original.isFileURL else { throw DirectUploadFailure.message("Drop existing files or folders from Finder.") }
            let info = try original.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
            guard info.isSymbolicLink != true, info.isAliasFile != true else { skipped += 1; continue }
            let url = try Self.canonicalURL(original)
            if roots.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) { continue }
            roots.append(url)
        }
        func add(_ url: URL, relative: String) throws {
            guard !excluded.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else {
                throw DirectUploadFailure.message("Choose originals outside CloudDrive's mount, cache and upload records folder.")
            }
            if seen.contains(url.path) { skipped += 1; return }
            guard additions.count + jobs.count < 10_000 else { throw DirectUploadFailure.message("The queue supports 10,000 files. Upload this folder in smaller batches.") }
            let identity = try UploadSourceIdentity.capture(url)
            var job = DirectUploadJob(batchID: batch, sourcePath: url.path,
                                      bookmark: try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil),
                                      source: identity, destination: connection.fingerprint,
                                      key: connection.prefix + "/" + relative, partSize: try DirectUploadJob.partSize(for: identity.size))
            // Reserve names within all queued batches. Remote collision checks happen before initiation.
            if (jobs + additions).contains(where: { $0.destination == job.destination && $0.key == job.key }) {
                job.key = Self.alternateKey(job.key, id: job.id)
            }
            try job.validate(); additions.append(job); seen.insert(url.path)
        }
        for root in roots {
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            guard !excluded.contains(where: { root.path == $0 || root.path.hasPrefix($0 + "/") }) else {
                throw DirectUploadFailure.message("CloudDrive's own files cannot be uploaded back into itself.")
            }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isUbiquitousItemKey])
            guard values.isUbiquitousItem != true else { throw DirectUploadFailure.message("Choose resident files on a local or external drive, rather than cloud placeholders.") }
            if values.isPackage == true { skipped += 1; continue }
            if values.isRegularFile == true { try add(root, relative: root.lastPathComponent); continue }
            guard values.isDirectory == true else { skipped += 1; continue }
            var enumerationFailed = false, entries = 0, files = 0
            let rootVolume = try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .volumeUUIDStringKey],
                    options: [.skipsPackageDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
                throw DirectUploadFailure.message("This folder could not be enumerated.")
            }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation(); entries += 1
                guard entries <= 100_000, enumerator.level <= 64 else { throw DirectUploadFailure.message("This folder exceeds the 100,000-entry or 64-level scan limit. Choose smaller folders.") }
                let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .volumeUUIDStringKey])
                if ignored.contains(url.lastPathComponent) || v.isSymbolicLink == true || v.isAliasFile == true || v.isPackage == true || v.volumeUUIDString != rootVolume {
                    enumerator.skipDescendants(); skipped += 1; continue
                }
                let canonical = try Self.canonicalURL(url)
                if excluded.contains(where: { canonical.path == $0 || canonical.path.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants(); skipped += 1; continue
                }
                if v.isRegularFile == true {
                    let relative = root.lastPathComponent + "/" + url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                    try add(canonical, relative: relative); files += 1
                } else if v.isDirectory != true { skipped += 1 }
            }
            guard !enumerationFailed else { throw DirectUploadFailure.message("Some folder entries could not be read. No files from this drop were added; reconnect the drive or check permissions.") }
            if files == 0 { skipped += 1 }
        }
        try store.insert(additions); jobs.append(contentsOf: additions); revision &+= 1
        return (jobs, skipped)
    }

    static func alternateKey(_ key: String, id: UUID) -> String {
        let url = URL(fileURLWithPath: key), ext = url.pathExtension
        let suffix = " (\(id.uuidString.lowercased()))"
        if ext.isEmpty { return key + suffix }
        return String(key.dropLast(ext.count + 1)) + suffix + "." + ext
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else {
            throw DirectUploadFailure.message("The source or records volume is unavailable. Reconnect it and retry.")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private func persist(_ job: DirectUploadJob) throws {
        guard let store, let index = jobs.firstIndex(where: { $0.id == job.id }) else { throw DirectUploadFailure.message("Upload records are unavailable.") }
        try store.save(job); jobs[index] = job; revision &+= 1
    }

    /// Only call after a store method has already committed this exact job atomically.
    private func rememberCommitted(_ job: DirectUploadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job; revision &+= 1 }
    }

    /// Individual calls remain exclusive; runBatch is the only multi-file scheduling authority.
    func run(id: UUID, remote: any MultipartRemote, destination: String, bytesPerSecond: Int64 = -1,
             stateUpdate: (@Sendable (UploadQueueState) async -> Void)? = nil,
             update: @escaping @Sendable ([DirectUploadJob]) async -> Void) async throws {
        guard active.isEmpty, !batching else { throw DirectUploadFailure.message("The upload queue is already running.") }
        stateObserver = stateUpdate
        defer { stateObserver = nil }
        try await execute(id: id, remote: remote, destination: destination,
                          resources: resources(bytesPerSecond: bytesPerSecond, jobs: jobs.filter { $0.id == id }), update: update)
    }

    func runBatch(remote: any MultipartRemote, destination: String, maxConcurrentFiles: Int = 4, bytesPerSecond: Int64 = -1,
                  stateUpdate: (@Sendable (UploadQueueState) async -> Void)? = nil,
                  update: @escaping @Sendable ([DirectUploadJob]) async -> Void) async throws {
        guard active.isEmpty, !batching, store != nil else { throw DirectUploadFailure.message("The upload queue is already running or its records are unavailable.") }
        batching = true; stateObserver = stateUpdate
        defer { batching = false; stateObserver = nil }
        let capacity = min(8, max(1, maxConcurrentFiles))
        let resources = resources(bytesPerSecond: bytesPerSecond, jobs: jobs.filter { !$0.terminal && $0.destination == destination })
        // One failing file must not cancel its siblings or end the batch: each child
        // reports its own error (already persisted as "needs attention") and the
        // first one is rethrown only after every other file has had its turn.
        var firstFailure: Error?
        try await withThrowingTaskGroup(of: (String, Error?).self) { group in
            var attempted = Set<UUID>(), reservedKeys = Set<String>(), inFlight = 0
            while true {
                try Task.checkCancellation()
                // Files that failed earlier go last, so they cannot hold up healthy work.
                while inFlight < capacity,
                      let next = nextEligible(destination: destination, attempted: attempted, reserved: reservedKeys) {
                    attempted.insert(next.id); reservedKeys.insert(next.key); inFlight += 1
                    group.addTask {
                        do {
                            try await self.execute(id: next.id, remote: remote, destination: destination, resources: resources, update: update)
                            return (next.key, nil)
                        } catch { return (next.key, error) }
                    }
                }
                guard inFlight > 0, let (key, error) = try await group.next() else { break }
                inFlight -= 1; reservedKeys.remove(key)
                if let error, firstFailure == nil, !(error is CancellationError) { firstFailure = error }
            }
        }
        await publish(update)
        if let firstFailure, !Task.isCancelled { throw firstFailure }
    }

    private func nextEligible(destination: String, attempted: Set<UUID>, reserved: Set<String>) -> DirectUploadJob? {
        func eligible(_ job: DirectUploadJob, allowAttention: Bool) -> Bool {
            !job.terminal && job.status != .cancelling && job.destination == destination &&
            (allowAttention || job.status != .attention) &&
            !attempted.contains(job.id) && !reserved.contains(job.key) && keyOwners[job.key] == nil
        }
        return jobs.first(where: { eligible($0, allowAttention: false) }) ?? jobs.first(where: { eligible($0, allowAttention: true) })
    }

    /// Serializes/coalesces callbacks so older snapshots can never overtake newer ones.
    private func publish(_ update: @escaping @Sendable ([DirectUploadJob]) async -> Void) async {
        publicationPending = true
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        while publicationPending {
            publicationPending = false
            let state = snapshotState()
            if let stateObserver { await stateObserver(state) }
            else { await update(state.jobs) }
        }
    }

    private func execute(id: UUID, remote: any MultipartRemote, destination: String, resources: Resources,
                         update: @escaping @Sendable ([DirectUploadJob]) async -> Void) async throws {
        guard !active.contains(id), let store, var job = jobs.first(where: { $0.id == id }), !job.terminal,
              job.destination == destination, keyOwners[job.key] == nil else {
            throw DirectUploadFailure.message("This upload is already active or its destination is reserved.")
        }
        active.insert(id); keyOwners[job.key] = id
        defer {
            active.remove(id)
            keyOwners = keyOwners.filter { $0.value != id }
        }
        var source: UploadSourceReader?
        do {
            try Task.checkCancellation(); try job.validate()
            // Reconcile commit before opening the source: a completed upload remains verifiable after unplugging.
            if let object = try await remote.head(key: job.key) {
                if try matches(object, job: job) {
                    job.status = .uploaded; job.phase = .complete; job.verifiedAt = Date(); job.message = "Verified size, upload identity and multipart checksum."
                    try persist(job); await publish(update); return
                }
                guard job.uploadID == nil, job.status != .checking, job.phase != .completing else { throw MultipartRemoteError.checksumMismatch }
                job.key = Self.alternateKey(job.key, id: job.id)
                guard keyOwners[job.key] == nil || keyOwners[job.key] == id else {
                    throw DirectUploadFailure.message("The alternate destination is busy. Resume after the other upload finishes.")
                }
                keyOwners[job.key] = id
                guard try await remote.head(key: job.key) == nil else { throw DirectUploadFailure.message("The reserved destination already exists. No object was replaced.") }
                try persist(job)
            }
            guard job.partSize <= resources.memoryLimit else {
                throw DirectUploadFailure.message("This newly added file needs a larger part buffer. Resume again to allocate its required bounded memory budget.")
            }
            let reader = try UploadSourceReader(job: job)
            source = reader
            try await reader.validate()
            if job.source.size == 0 {
                job.status = .checking; job.phase = .completing; try persist(job); await publish(update)
                try await remote.putEmpty(key: job.key, jobID: job.id)
            } else if job.source.size <= 8 * 1_048_576, job.uploadID == nil, job.parts.isEmpty,
                      let singleRemote = remote as? any SingleObjectRemote {
                try await resources.rate.waitToSend(bytes: job.source.size)
                let original = job
                job = try await withPayload(bytes: job.source.size, resources: resources) {
                    try await self.sendSmall(job: original, reader: reader, remote: singleRemote, update: update)
                }
            } else {
                guard job.singlePutMD5 == nil else { throw DirectUploadFailure.message("This transport cannot resume the saved single-request upload.") }
                let isFresh = job.uploadID == nil
                if job.uploadID == nil {
                    // Persist the exact key before initiating. Never send parts until upload ID is committed locally.
                    job.status = .uploading; job.phase = .initiating; try persist(job); await publish(update)
                    job.uploadID = try await remote.create(key: job.key, jobID: job.id)
                    job.uploadCreatedAt = Date(); job.phase = .transferring; try persist(job)
                }
                guard let uploadID = job.uploadID else { throw MultipartRemoteError.invalidResponse }
                // A newly initiated session has no parts; only a recovered session needs ListParts.
                let remoteParts: [RemoteUploadPart] = isFresh ? [] : try await remote.list(key: job.key, uploadID: uploadID)
                let byNumber = Dictionary(uniqueKeysWithValues: remoteParts.map { ($0.number, $0) })
                job.parts = job.parts.filter { part in
                    byNumber[part.number]?.etag == part.etag && byNumber[part.number]?.size == part.size
                }
                job.status = .uploading; job.message = "Keep the source drive connected. Confirmed parts survive pause and restart."
                if !isFresh { try store.reconcileParts(job); rememberCommitted(job) }
                else { try persist(job) }
                await publish(update)
                // Recover parts accepted remotely just before the app lost its local acknowledgement.
                for part in remoteParts where !job.parts.contains(where: { $0.number == part.number }) {
                    guard part.number <= job.partCount, part.size == min(job.partSize, job.source.size - Int64(part.number - 1) * job.partSize) else { throw MultipartRemoteError.invalidResponse }
                    let digest = try await withPayload(bytes: part.size, resources: resources) {
                        let (_, digest) = try await reader.readPart(number: part.number)
                        return digest
                    }
                    if digest == part.etag {
                        let confirmed = ConfirmedUploadPart(number: part.number, etag: digest, md5: digest, size: part.size)
                        job.parts.append(confirmed); try store.savePart(confirmed, job: job); rememberCommitted(job); await publish(update)
                    }
                }
                let present = Set(job.parts.map(\.number))
                let missing = (1...job.partCount).filter { !present.contains($0) }
                // Rolling slots: finishing one part immediately admits the next. Payload leases live in children.
                let key = job.key, fileSize = job.source.size, partSize = job.partSize
                let concurrency = min(6, max(1, Int(resources.memoryLimit / partSize)))
                try await withThrowingTaskGroup(of: ConfirmedUploadPart.self) { group in
                    var next = 0
                    for _ in 0..<min(concurrency, missing.count) {
                        let number = missing[next]; next += 1
                        let bytes = min(partSize, fileSize - Int64(number - 1) * partSize)
                        group.addTask {
                            try await self.sendPart(reader: reader, number: number, bytes: bytes, key: key, uploadID: uploadID, remote: remote, resources: resources)
                        }
                    }
                    for try await part in group {
                        guard part.etag == part.md5 else { throw MultipartRemoteError.checksumMismatch }
                        job.parts.append(part)
                        try store.savePart(part, job: job); rememberCommitted(job); await publish(update)
                        if next < missing.count {
                            let number = missing[next]; next += 1
                            let bytes = min(partSize, fileSize - Int64(number - 1) * partSize)
                            group.addTask {
                                try await self.sendPart(reader: reader, number: number, bytes: bytes, key: key, uploadID: uploadID, remote: remote, resources: resources)
                            }
                        }
                    }
                }
                try Task.checkCancellation(); try await reader.validate()
                guard job.expectedETag != nil else { throw MultipartRemoteError.invalidResponse }
                job.status = .checking; job.phase = .completing; try persist(job); await publish(update)
                // A failed completion response is ambiguous. Next resume HEAD-checks before retrying this commit.
                try await remote.complete(key: job.key, uploadID: uploadID, parts: job.parts)
            }
            guard let object = try await remote.head(key: job.key), try matches(object, job: job) else { throw MultipartRemoteError.checksumMismatch }
            job.status = .uploaded; job.phase = .complete; job.verifiedAt = Date(); job.message = "Verified size, upload identity and multipart checksum."
            try persist(job); await publish(update)
            await reader.close()
        } catch {
            await source?.close()
            // Use committed in-memory state, not an uncommitted successful part, if SQLite failed.
            if var saved = jobs.first(where: { $0.id == id }) {
                if Task.isCancelled { saved.status = .paused; saved.message = "Progress saved. Resume checks confirmed parts on R2." }
                else {
                    saved.status = .attention
                    saved.message = (error as? DirectUploadFailure)?.localizedDescription ?? (error as? MultipartRemoteError)?.localizedDescription ?? "Upload interrupted. Check the original drive, network and records folder, then resume. Confirmed parts are retained."
                }
                try persist(saved); await publish(update)
            }
            if !Task.isCancelled { throw error }
        }
    }

    private func withPayload<T: Sendable>(bytes: Int64, resources: Resources,
                                          operation: @Sendable () async throws -> T) async throws -> T {
        let token = try await resources.memory.acquire(bytes: bytes)
        do {
            let result = try await operation()
            await resources.memory.release(token: token)
            return result
        } catch {
            await resources.memory.release(token: token)
            throw error
        }
    }

    private func sendPart(reader: UploadSourceReader, number: Int, bytes: Int64, key: String, uploadID: String,
                          remote: any MultipartRemote, resources: Resources) async throws -> ConfirmedUploadPart {
        try await resources.rate.waitToSend(bytes: bytes)
        return try await withPayload(bytes: bytes, resources: resources) {
            try await reader.uploadPart(number: number, key: key, uploadID: uploadID, remote: remote)
        }
    }

    private func sendSmall(job original: DirectUploadJob, reader: UploadSourceReader, remote: any SingleObjectRemote,
                           update: @escaping @Sendable ([DirectUploadJob]) async -> Void) async throws -> DirectUploadJob {
        var job = original
        let (data, digest) = try await reader.readWhole()
        if let saved = job.singlePutMD5, saved != digest { throw MultipartRemoteError.checksumMismatch }
        job.singlePutMD5 = digest; job.phase = .completing; job.status = .uploading
        try persist(job); await publish(update)
        try await remote.putObject(key: job.key, jobID: job.id, data: data, md5: digest)
        return job
    }

    private func matches(_ object: RemoteUploadObject, job: DirectUploadJob) throws -> Bool {
        guard object.jobID == job.id.uuidString else { return false }
        guard let expected = job.expectedETag, object.size == job.source.size, object.etag == expected else { throw MultipartRemoteError.checksumMismatch }
        return true
    }

    func cancel(id: UUID, remote: any MultipartRemote, destination: String) async throws -> [DirectUploadJob] {
        guard active.isEmpty && !batching, var job = jobs.first(where: { $0.id == id }), job.destination == destination, !job.terminal else {
            throw DirectUploadFailure.message("Pause the active queue before cancelling a file. Use its original destination connection.")
        }
        active.insert(id); defer { active.remove(id) }
        if job.uploadID == nil, job.phase == .queued || job.phase == .initiating {
            job.status = .cancelled; job.message = "Cancelled before any payload was sent. The original file is unchanged."
            try persist(job); return jobs
        }
        if let object = try await remote.head(key: job.key), try matches(object, job: job) {
            job.status = .uploaded; job.phase = .complete; job.verifiedAt = Date(); job.message = "Upload completed before cancellation; the remote object was retained."
        } else {
            job.status = .cancelling; try persist(job)
            if let uploadID = job.uploadID { try await remote.abort(key: job.key, uploadID: uploadID) }
            job.status = .cancelled; job.message = "Cancelled. The original file is unchanged."
        }
        try persist(job); return jobs
    }

    func restartExpired(id: UUID, remote: any MultipartRemote, destination: String) async throws -> [DirectUploadJob] {
        guard active.isEmpty && !batching, let store, var job = jobs.first(where: { $0.id == id }), job.destination == destination, !job.terminal, let uploadID = job.uploadID else {
            throw DirectUploadFailure.message("Only an interrupted multipart session can be restarted.")
        }
        active.insert(id); defer { active.remove(id) }
        if let object = try await remote.head(key: job.key), try matches(object, job: job) {
            job.status = .uploaded; job.phase = .complete; job.verifiedAt = Date(); try persist(job); return jobs
        }
        do { _ = try await remote.list(key: job.key, uploadID: uploadID) }
        catch MultipartRemoteError.expired {
            job.uploadID = nil; job.uploadCreatedAt = nil; job.parts = []; job.status = .paused; job.phase = .queued
            job.message = "Expired upload reset. Resume starts a new multipart session."
            try store.reconcileParts(job); try persist(job); return jobs
        }
        throw DirectUploadFailure.message("This upload still exists on R2. Resume it to retain the confirmed parts.")
    }

    func clearFinished(id: UUID? = nil) throws -> [DirectUploadJob] {
        guard active.isEmpty && !batching, let store else { throw DirectUploadFailure.message("Pause the active queue first.") }
        if let id, !jobs.contains(where: { $0.id == id && $0.terminal }) {
            throw DirectUploadFailure.message("Only finished uploads can be removed from history. Pause and cancel an unfinished upload first.")
        }
        try store.removeFinished(id: id); jobs = try store.load(); revision &+= 1; return jobs
    }
    #if DEBUG
    func closeForTesting() {
        precondition(active.isEmpty && !batching)
        store = nil; jobs = []; directory = nil
    }
    #endif
}
