import Foundation
import AppKit

/// Built once per queue publication, not once per label or animation frame.
struct DirectUploadQueueMetrics {
    var pending = 0
    var paused = 0
    var attention = 0
    var active = 0
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var pendingByDestination: [String: Int] = [:]
    var orderedJobs: [DirectUploadJob] = []
    var inProgressJobs: [DirectUploadJob] = []
    var attentionJobs: [DirectUploadJob] = []
    var completedJobs: [DirectUploadJob] = []
    var jobsByID: [UUID: DirectUploadJob] = [:]
    var allCancelled: Bool
    var progress: Double

    init(jobs: [DirectUploadJob]) {
        var finished: [DirectUploadJob] = []
        orderedJobs.reserveCapacity(jobs.count)
        jobsByID.reserveCapacity(jobs.count)
        allCancelled = !jobs.isEmpty
        for job in jobs {
            jobsByID[job.id] = job
            completedBytes += job.completedBytes
            totalBytes += job.source.size
            allCancelled = allCancelled && job.status == .cancelled
            if job.terminal {
                finished.append(job)
                if job.status == .uploaded { completedJobs.append(job) }
            } else {
                if job.status == .attention || job.status == .cancelling { attentionJobs.append(job) }
                else { inProgressJobs.append(job) }
                pending += 1
                pendingByDestination[job.destination, default: 0] += 1
                if job.status == .paused { paused += 1 }
                if job.status == .attention || job.status == .cancelling { attention += 1 }
                if job.status == .uploading || job.status == .checking { active += 1 }
                // Keep queue order while files change between Waiting, Uploading and Checking.
                orderedJobs.append(job)
            }
        }
        completedJobs.reverse()
        orderedJobs.append(contentsOf: finished.reversed())
        progress = totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : (!jobs.isEmpty && pending == 0 ? 1 : 0)
    }
    func foreignJobs(destination: String) -> Int { pending - (pendingByDestination[destination] ?? 0) }
}

@MainActor final class DirectUploadController: ObservableObject {
    @Published private(set) var jobs: [DirectUploadJob] = [] {
        didSet { metrics = DirectUploadQueueMetrics(jobs: jobs); queueRevision &+= 1 }
    }
    private(set) var metrics = DirectUploadQueueMetrics(jobs: [])
    private(set) var queueRevision: UInt64 = 0
    @Published private(set) var isActive = false
    @Published private(set) var preparing = false
    @Published private(set) var loaded = false
    @Published private(set) var message = ""
    @Published private(set) var lastOperationFailed = false
    @Published private(set) var recordsDirectory: URL
    @Published private(set) var speed: Double = 0
    /// Bytes currently being sent but not yet confirmed by R2. Display-only.
    @Published private(set) var inFlightBytes: Int64 = 0
    @Published private(set) var concurrency: DirectUploadConcurrency
    private var pendingState: UploadQueueState?
    private var lastSeenRevision: UInt64 = 0
    private var snapshotTask: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast
    private var telemetryTask: Task<Void, Never>?
    private let engine = DirectUploadEngine()
    private let makeUploadRemote: (Connection) -> any MultipartRemote
    private var runner: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    var catalogDestination: () -> String? = { nil }
    var catalogDelivery: (@MainActor ([UploadCatalogHint]) async throws -> Void)?
    func requestCatalogDelivery() {
        guard catalogTask == nil, let destination = catalogDestination(), let delivery = catalogDelivery else { return }
        let engine = self.engine
        catalogTask = Task { [weak self] in
            defer {
                self?.catalogTask = nil
                if let self, self.catalogDestination() != destination { self.requestCatalogDelivery() }
            }
            while !Task.isCancelled {
                guard self?.catalogDestination() == destination else { return }
                do {
                    let hints = try await engine.pendingCatalogHints(destination:destination)
                    guard !hints.isEmpty else { return }
                    try await delivery(hints)
                    try Task.checkCancellation()
                    try await engine.acknowledgeCatalogHints(hints)
                } catch {
                    // Upload success and its receipt are independent of catalog availability.
                    do { try await Task.sleep(for:.seconds(5)) } catch { return }
                }
            }
        }
    }
    private var restoreTask: Task<Void, Never>?
    private var startedAt = Date()
    private var initialBytes: Int64 = 0
    private var selectedJobID: UUID?
    private var recordsUnavailable = false
    private let rememberLocation: Bool
    private let preferences: UserDefaults
    private var requiresExistingRecords: Bool
    var canStart: () -> Bool = { false }
    var namespaceEnqueue: (@MainActor ([URL], Connection) async throws -> Bool)?
    var uploadRate: () -> Int64 = { -1 }
    var holdsDestination: Bool { !loaded || recordsUnavailable || isActive || preparing || jobs.contains { !$0.terminal } }
    var canQuit: Bool { !isActive && !preparing }
    var needsRecordsRecovery: Bool { recordsUnavailable }
    var hasUnfinishedOrUnavailableQueue: Bool { recordsUnavailable || preparing || isActive || metrics.pending > 0 }
    var hasSavedTransferRecords: Bool { hasUnfinishedOrUnavailableQueue || !jobs.isEmpty }
    func statusSummary(destination: String) -> DirectUploadStatusSummary {
        DirectUploadStatusSummary(pending: metrics.pending, paused: metrics.paused,
                                  attention: metrics.attention, foreign: metrics.foreignJobs(destination: destination),
                                  active: isActive, preparing: preparing, recordsUnavailable: recordsUnavailable)
    }
    var completedBytes: Int64 { metrics.completedBytes }
    var totalBytes: Int64 { metrics.totalBytes }
    var progress: Double {
        guard inFlightBytes > 0, metrics.totalBytes > 0 else { return metrics.progress }
        return min(1, Double(metrics.completedBytes + inFlightBytes) / Double(metrics.totalBytes))
    }
    var eta: TimeInterval? {
        guard isActive, speed > 0 else { return nil }
        if let selectedJobID, let job = jobs.first(where: { $0.id == selectedJobID }) {
            return Double(max(0, job.source.size - job.completedBytes)) / speed
        }
        return Double(max(0, totalBytes - completedBytes)) / speed
    }

    init(defaultDirectory: URL, rememberLocation: Bool = true, preferences: UserDefaults = .standard,
         makeUploadRemote: @escaping (Connection) -> any MultipartRemote = { S3MultipartRemote(connection: $0) }) {
        self.makeUploadRemote = makeUploadRemote
        self.rememberLocation = rememberLocation
        self.preferences = preferences
        concurrency = rememberLocation ? (DirectUploadConcurrency(rawValue: preferences.integer(forKey: "directUploadConcurrency")) ?? .four) : .four
        if rememberLocation, let path = preferences.string(forKey: "directUploadRecordsFolder"), path.hasPrefix("/") {
            recordsDirectory = URL(fileURLWithPath: path)
            requiresExistingRecords = true
        } else { recordsDirectory = defaultDirectory; requiresExistingRecords = false }
    }

    func restoreIfNeeded() async {
        if let restoreTask { await restoreTask.value; return }
        guard !loaded || recordsUnavailable else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.jobs = try await self.engine.open(directory: self.recordsDirectory, recoverExisting: self.requiresExistingRecords)
                self.recordsUnavailable = false
                if self.jobs.contains(where: { !$0.terminal }) { self.message = "Saved uploads recovered. Resume to check R2 and continue from confirmed parts." }
            } catch {
                self.recordsUnavailable = true
                self.message = "Upload records are unavailable. Reconnect their drive or choose Recover Upload Records. You can use an external records folder when internal storage is full."
            }
            self.loaded = true
            self.requestCatalogDelivery()
        }
        restoreTask = task; await task.value; restoreTask = nil
    }

    func chooseRecords(recover: Bool = false) {
        guard !isActive, !preparing else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.prompt = recover ? "Recover" : "Use Folder"
        picker.message = recover ? "Select the CloudDrive Upload Records folder to recover its saved queue." : "A small private records folder will be created here. File contents are never copied into it. This location can be on an external drive."
        guard picker.runModal() == .OK, let selected = picker.url else { return }
        let directory = recover ? selected : selected.appendingPathComponent("CloudDrive Upload Records", isDirectory: true)
        preparing = true
        lastOperationFailed = false
        Task {
            defer { preparing = false }
            do {
                jobs = try await engine.open(directory: directory, recoverExisting: recover, createParentDirectories: false)
                recordsDirectory = directory; recordsUnavailable = false; loaded = true
                requiresExistingRecords = true
                if rememberLocation { preferences.set(directory.path, forKey: "directUploadRecordsFolder") }
                requestCatalogDelivery()
                message = "Upload records ready. Originals remain on the source drive."
            } catch { report(error) }
        }
    }

    func chooseFiles(connection: Connection, excluded: [URL]) {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = true; picker.allowsMultipleSelection = true
        picker.prompt = "Upload Directly"; picker.message = "Choose files or folders. Originals remain on their drive; uploads resume from saved parts."
        if picker.runModal() == .OK { enqueue(picker.urls, connection: connection, excluded: excluded) }
    }

    func enqueue(_ urls: [URL], connection: Connection, excluded: [URL]) {
        guard !preparing else { return }
        preparing = true
        lastOperationFailed = false
        // Keep the drag/picker access alive until persistent per-file bookmarks have been made.
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        Task {
            defer { for url in scoped { url.stopAccessingSecurityScopedResource() }; preparing = false }
            await restoreIfNeeded()
            do {
                if let namespaceEnqueue, try await namespaceEnqueue(urls, connection) {
                    message = "Files were submitted to the drive owner. View sync status for cloud completion."
                    return
                }
                let result = try await engine.enqueue(urls: urls, connection: connection, excluded: excluded)
                receivedState(await engine.snapshotState(), force: !isActive)
                message = result.skipped == 0 ? "Files queued. Keep the source drive connected." : "\(result.skipped) duplicate, unsupported or empty items skipped. Empty folders, packages, aliases and symlinks are not uploaded."
                preparing = false
                if !isActive, canStart() { resume(connection: connection, bytesPerSecond: uploadRate()) }
            } catch { report(error) }
        }
    }

    func resume(connection: Connection, bytesPerSecond: Int64 = -1, jobID: UUID? = nil) {
        guard loaded, !recordsUnavailable, !preparing, !isActive else { return }
        guard canStart() else { message = "Finish Finder uploads and switch to direct upload before resuming."; return }
        do { try connection.validate() } catch { report(error); return }
        let pending = jobs.filter { !$0.terminal && $0.status != .cancelling && $0.destination == connection.fingerprint && (jobID == nil || $0.id == jobID) }.map(\.id)
        guard !pending.isEmpty else { message = "No resumable files for this connection. Saved files remain bound to their original destination."; return }
        lastOperationFailed = false
        selectedJobID = jobID
        isActive = true; startedAt = Date(); initialBytes = completedBytes; speed = 0
        runner = Task { [weak self] in
            guard let self else { return }
            let remote = makeUploadRemote(connection)
            let telemetryRemote = remote as? S3MultipartRemote
            if let telemetryRemote { startTelemetry(remote: telemetryRemote) }
            defer { telemetryRemote?.close(); self.telemetryTask?.cancel(); self.telemetryTask = nil; self.isActive = false; self.speed = 0; self.inFlightBytes = 0; self.runner = nil; self.selectedJobID = nil }
            do {
                if let jobID {
                    try await engine.run(id: jobID, remote: remote, destination: connection.fingerprint,
                                         bytesPerSecond: bytesPerSecond,
                                         stateUpdate: { [weak self] state in await self?.receivedState(state) }, update: { _ in })
                } else {
                    try await engine.runBatch(remote: remote, destination: connection.fingerprint,
                                              maxConcurrentFiles: self.concurrency.rawValue, bytesPerSecond: bytesPerSecond,
                                              stateUpdate: { [weak self] state in await self?.receivedState(state) }, update: { _ in })
                }
            } catch {
                if !Task.isCancelled { self.report(error) }
            }
            // The batch has drained every request. Cancel delayed UI delivery before publishing final authoritative state.
            self.receivedState(await engine.snapshotState(), force: true)
        }
    }

    private func receivedState(_ state: UploadQueueState, force: Bool = false) {
        if state.revision >= lastSeenRevision {
            lastSeenRevision = state.revision; pendingState = state
        }
        if force || Date().timeIntervalSince(lastPublishedAt) >= 0.1 {
            snapshotTask?.cancel(); snapshotTask = nil; publishPending()
        } else if snapshotTask == nil {
            snapshotTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                self.snapshotTask = nil; self.publishPending()
            }
        }
    }
    private func publishPending() {
        guard let state = pendingState else { return }
        pendingState = nil; publishSnapshot(state.jobs)
    }
    private func publishSnapshot(_ snapshot: [DirectUploadJob]) {
        jobs = snapshot; lastPublishedAt = Date()
        requestCatalogDelivery()
        if telemetryTask == nil {
            speed = Double(max(0, completedBytes - initialBytes)) / max(1, Date().timeIntervalSince(startedAt))
        }
    }
    private func startTelemetry(remote: S3MultipartRemote) {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            let clock = ContinuousClock()
            var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = [(clock.now, remote.sentPayloadBytes())]
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                let now = clock.now
                samples.append((now, remote.sentPayloadBytes()))
                let cutoff = now.advanced(by: .seconds(-5))
                while samples.count > 2 && samples[1].time < cutoff { samples.removeFirst() }
                let duration = samples[0].time.duration(to: now).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                self.speed = Double(max(0, samples.last!.bytes - samples[0].bytes)) / max(0.001, seconds)
                self.inFlightBytes = remote.inFlightPayloadBytes()
            }
        }
    }
    func changeConcurrency(_ requested: DirectUploadConcurrency) {
        guard !isActive, !preparing else { return }
        concurrency = requested
        if rememberLocation { preferences.set(requested.rawValue, forKey: "directUploadConcurrency") }
    }
    func pause() { runner?.cancel(); message = "Pausing… confirmed parts are retained. An in-flight part may need to be retried." }
    func pauseAndWait() async { runner?.cancel(); await runner?.value }

    func cancel(_ id: UUID, connection: Connection) {
        let local = jobs.first(where: { $0.id == id }).map { $0.uploadID == nil && ($0.phase == .queued || $0.phase == .initiating) } ?? false
        performControl(connection: connection, requiresRemote: !local) { engine, remote in
            try await engine.cancel(id: id, remote: remote, destination: connection.fingerprint)
        }
    }
    func restartExpired(_ id: UUID, connection: Connection) { performControl(connection: connection) { engine, remote in
        try await engine.restartExpired(id: id, remote: remote, destination: connection.fingerprint)
    } }
    private func performControl(connection: Connection, requiresRemote: Bool = true, operation: @escaping (DirectUploadEngine, S3MultipartRemote) async throws -> [DirectUploadJob]) {
        guard !isActive, !preparing, !requiresRemote || canStart() else { message = "Pause uploads and finish Finder writes before changing a remote upload."; return }
        if requiresRemote { do { try connection.validate() } catch { report(error); return } }
        isActive = true
        runner = Task {
            let remote = S3MultipartRemote(connection: connection)
            defer { remote.close(); isActive = false; runner = nil; requestCatalogDelivery() }
            do { jobs = try await operation(engine, remote) }
            catch { report(error); jobs = await engine.snapshot() }
        }
    }
    func clearFinished(_ id: UUID? = nil) {
        guard !isActive, !preparing else { return }
        preparing = true
        lastOperationFailed = false
        Task {
            defer { preparing = false }
            do { jobs = try await engine.clearFinished(id: id); requestCatalogDelivery(); message = "Completed history cleared. Remote objects and originals were retained." }
            catch { report(error) }
        }
    }
    #if DEBUG
    func relinquishForTesting() async {
        await pauseAndWait()
        catalogTask?.cancel(); await catalogTask?.value; catalogTask = nil
        await engine.closeForTesting()
    }
    #endif
    private func report(_ error: Error) {
        message = safe(error); lastOperationFailed = true
    }
    private func safe(_ error: Error) -> String {
        (error as? DirectUploadFailure)?.localizedDescription ?? (error as? MultipartRemoteError)?.localizedDescription ?? "The operation could not be confirmed. Upload records and original files were preserved. Check the source and records volumes, then retry."
    }
}
