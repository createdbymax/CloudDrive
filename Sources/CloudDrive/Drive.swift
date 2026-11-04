import AppKit
import CryptoKit
import Foundation
import Darwin

@MainActor final class Drive: ObservableObject {
    @Published var connection = Connection() {
        didSet {
            if oldValue.fingerprint != connection.fingerprint { receipt = nil; uploadProgress = nil; storageSnapshot = nil }
        }
    }
    @Published private(set) var mountState: MountState = .checking
    @Published private(set) var uploads: UploadState = .unknown
    @Published private(set) var busy = false
    @Published private(set) var mounted = false
    @Published private(set) var running = false
    @Published private(set) var operationResult = ""
    @Published private(set) var lastOperationFailed = false
    @Published private(set) var detail = ""
    @Published private(set) var receipt: VerificationReceipt?
    @Published private(set) var keychainNeedsApproval = false
    @Published private(set) var automaticSpaceSaving = false
    @Published private(set) var uploadProgress: UploadProgressSnapshot?
    @Published private(set) var uploadSampledAt: Date?
    @Published private(set) var uploadLimit: UploadLimit = .unlimited
    @Published private(set) var appliedUploadLimit: UploadLimit?
    @Published private(set) var activity: [UploadItem] = []
    @Published private(set) var activityAvailable = false
    @Published private(set) var activitySessionID: UUID?
    @Published private(set) var storageSnapshot: LocalStorageSnapshot?
    @Published private(set) var diagnostics: [DiagnosticEvent] = []
    private var record: WorkerRecord?
    private var worker: Process?
    private var ownerLock: OwnerLock?
    private var recoveryRequired = true
    private var polling: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var pollingNow = false
    private var storageScanning = false
    private let fixtureSource: URL?
    private let fixtureUploadLimitMiB: Int?
    private let useKeychain: Bool
    let root: URL
    let binary: URL
    let helper: URL
    var mountpoint: URL { root.appendingPathComponent("Drive") }
    var cache: URL { root.appendingPathComponent("Cache/" + connection.fingerprint) }
    private var store: WorkerRecordStore { get throws { try WorkerRecordStore(directory: root) } }
    var status: String { mountState.text }
    var uploadStatus: String { uploads.text }
    var verification: String { receipt?.destinationFingerprint == connection.fingerprint ? receipt?.text ?? "" : "" }
    var canConnect: Bool { !busy && ownerLock != nil && record == nil && !recoveryRequired && !mounted }
    var canEject: Bool { !busy && record != nil }
    var canQuit: Bool { !busy && record == nil && !mounted }

    init(root: URL? = nil, binary: URL? = nil, helper: URL? = nil, fixtureSource: URL? = nil, fixtureUploadLimitMiB: Int? = nil, useKeychain: Bool = true, autoRecover: Bool = true) {
        // Keep the existing state/lock/cache namespace across the CloudDrive rename.
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BucketDrive")
        self.binary = binary ?? Bundle.main.resourceURL!.appendingPathComponent("rclone")
        self.helper = helper ?? Bundle.main.resourceURL!.appendingPathComponent("CloudDriveHelper")
        self.fixtureSource = fixtureSource
        self.fixtureUploadLimitMiB = fixtureUploadLimitMiB
        self.useKeychain = useKeychain
        if useKeychain { self.uploadLimit = UploadLimit(rawValue: UserDefaults.standard.integer(forKey: "uploadLimitMbps")) ?? .unlimited }
        if autoRecover { Task { [weak self] in await self?.recover() } }
    }
    deinit { polling?.cancel(); operation?.cancel() }
    func openDrive() { if mounted { NSWorkspace.shared.open(mountpoint) } }
    func showStorage() { NSWorkspace.shared.open(root) }
    func refreshLocalStorage() async {
        guard !storageScanning else { return }
        storageScanning = true
        defer { storageScanning = false }
        let root = root, cache = cache, fingerprint = connection.fingerprint
        let snapshot = await Task.detached(priority: .utility) { LocalStorageScanner.scan(root: root, cache: cache) }.value
        guard connection.fingerprint == fingerprint else { return }
        storageSnapshot = snapshot
    }
    func cancelOperation() { operation?.cancel() }
    func changeUploadLimit(_ requested: UploadLimit) async {
        guard !busy, !recoveryRequired else { return }
        await perform { [self] in
            appliedUploadLimit = nil
            if let owned = record {
                try await validateIdentity(owned)
                _ = try await authenticatedStats(owned)
                appliedUploadLimit = try await client(owned).setUploadLimit(requested)
            }
            uploadLimit = requested
            if useKeychain { UserDefaults.standard.set(requested.rawValue, forKey: "uploadLimitMbps") }
            operationResult = record == nil ? "Upload limit saved for the next connection. Downloads remain unlimited." : "Upload limit applied and checked: \(requested.label). Downloads remain unlimited."
        }
    }
    func retryUpload(_ item: UploadItem, sessionID: UUID) async {
        guard !busy, !recoveryRequired, let owned = record else { return }
        await perform { [self] in
            guard owned.sessionID == sessionID, activitySessionID == sessionID else {
                throw DriveError.message("The upload belongs to an earlier worker session. Refresh its status before retrying.")
            }
            try await validateIdentity(owned)
            let stats = try await authenticatedStats(owned)
            let queue = try UploadQueue.decode(await client(owned).call(route: "vfs/queue"))
            guard let current = queue.queue.first(where: { $0.id == item.id }),
                  current.name == item.name, current.size == item.size, current.tries == item.tries,
                  !current.uploading else { throw DriveError.message("This upload has changed or is already active. Refresh its status before retrying.") }
            try await client(owned).requestUploadRetry(current, fs: stats.fs)
            operationResult = "Retry requested for the waiting upload. This does not pause active transfers or confirm completion."
        }
    }

    func loadSavedConnection() async {
        guard !busy else { return }
        await perform { [self] in
            operationResult = "Respond to macOS's Keychain prompt if shown. You have up to 5 minutes; Cancel returns control without using a late result."
            if let saved = try await Credentials.loadBounded(allowInteraction: true) {
                connection = saved; keychainNeedsApproval = false
                operationResult = "Saved connection loaded. Retry Recovery if a previous worker exists."
            } else { operationResult = "No saved connection was found. Enter it in the form." }
        }
    }

    func recover() async {
        await perform { [self] in
            generation = UUID(); uploadProgress = nil; polling?.cancel(); polling = nil
            mountState = .checking; uploads = .unknown; detail = ""
            if ownerLock == nil {
                ownerLock = try await offUI {
                    try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    return try OwnerLock(directory: self.root)
                }
            }
            if useKeychain {
                do {
                    if let saved = try await Credentials.loadBounded() { connection = saved; keychainNeedsApproval = false }
                } catch {
                    keychainNeedsApproval = true
                    operationResult = safeMessage(error)
                }
            }
            var loaded = try await offUI { try self.store.load() }
            let pendingLaunch = try await offUI { try self.store.loadIntent() }
            if let intent = pendingLaunch {
                recoveryRequired = true
                if let existing = loaded {
                    guard intent.sessionID == existing.sessionID else { throw DriveError.message("Worker and pending launch sessions disagree. Both records were preserved.") }
                    // Retain fallback evidence until the complete record is validated below.
                } else {
                    guard intent.destinationFingerprint == connection.fingerprint, intent.cachePath == cache.path,
                          intent.mountPath == mountpoint.path, intent.expectedRemote == remote else {
                        throw DriveError.message("Pending launch belongs to a different configuration. It was preserved.")
                    }
                    let pid: Int32
                    do { pid = try await ControlClient(port: intent.controlPort, token: intent.controlToken).pid() }
                    catch { throw DriveError.message("An interrupted startup could not be authenticated. Its launch record and cache were preserved; no second worker was started. Retry Recovery or retain these records for diagnosis.") }
                    let identity = try ProcessIdentity.capture(pid: pid)
                    var reconstructed = intent.record(process: identity)
                    // An intent has no persisted process start identity yet. Establish
                    // its executable against the launch digest before adopting it.
                    try await offUI {
                        try reconstructed.validate(binary: URL(fileURLWithPath: identity.executablePath), destinationFingerprint: self.connection.fingerprint, cachePath: self.cache.path, mountPath: self.mountpoint.path)
                    }
                    try await validateIdentity(reconstructed)
                    let stats = try await authenticatedStats(reconstructed, requireObservedBinding: false)
                    reconstructed.observedFS = stats.fs; reconstructed.observedCachePath = stats.diskCache.path
                    // A mount may have completed just before the app stopped. Bind it by the exact NFS port.
                    if let entry = MountInspector.exactEntry(at: mountpoint.path, entries: try MountInspector.snapshot()) {
                        guard entry.type == "nfs", entry.source == "127.0.0.1:/", try await mountUsesPort(reconstructed) else {
                            throw DriveError.message("Interrupted launch has an unrelated mount. It was left intact.")
                        }
                        reconstructed.mountID = entry.id
                    }
                    record = reconstructed
                    try await offUI { try self.store.save(reconstructed) }
                    try await offUI { try self.store.removeIntent(expectedSessionID: intent.sessionID) }
                    loaded = reconstructed
                }
            }
            let entries = try MountInspector.snapshot()
            guard var loaded else {
                guard MountInspector.exactEntry(at: mountpoint.path, entries: entries) == nil else {
                    throw DriveError.message("A volume occupies this app's mount location without an owned worker record. Leave it intact and eject it through its owning app.")
                }
                record = nil; running = false; mounted = false; recoveryRequired = false
                mountState = .disconnected
                if !keychainNeedsApproval { operationResult = "Ready to connect. Pending cache is retained." }
                return
            }
            // Keep the record visible even when validation fails; never replace a questionable worker.
            record = loaded; running = false; recoveryRequired = true
            if !loaded.process.matchesRunningProcess() {
                // Only retire an ended session after checking its recorded configuration and mount.
                try await offUI { try loaded.validateSession(destinationFingerprint: self.connection.fingerprint, cachePath: self.cache.path, mountPath: self.mountpoint.path, requireRunning: false) }
                guard loaded.expectedRemote == remote else { throw DriveError.message("Ended worker belongs to another destination. Its state was preserved.") }
                // proc_pidpath can become unavailable while an exiting process is
                // still being torn down. Wait briefly; never interpret that gap as
                // permission to adopt or signal a different process.
                let exitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !loaded.process.hasExited, ContinuousClock.now < exitDeadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard loaded.process.hasExited else {
                    throw DriveError.message("The recorded PID is occupied by a different or unverifiable process. Its mount and recovery state were preserved; no signal was sent.")
                }
                if try await ownedMount(loaded, entries: entries) {
                    operationResult = "Removing the recorded stale Finder mount. Local cache is retained…"
                    let unmount = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [loaded.mountPath], timeout: 10))
                    guard unmount.exitCode == 0 else { throw DriveError.message("Stale Finder mount is busy. Close its windows/files and Retry Recovery. No force was used.") }
                }
                guard !loaded.process.matchesRunningProcess(), MountInspector.exactEntry(at: loaded.mountPath, entries: try MountInspector.snapshot()) == nil else {
                    throw DriveError.message("Ended session could not be retired safely. Cache and record retained.")
                }
                try await offUI {
                    if let pending = try self.store.loadIntent(), pending.sessionID == loaded.sessionID {
                        try self.store.removeIntent(expectedSessionID: loaded.sessionID)
                    }
                    try self.store.remove(expectedSessionID: loaded.sessionID)
                }
                record = nil; worker = nil; running = false; mounted = false; recoveryRequired = false
            uploadProgress = nil; activity = []; activityAvailable = false
                mountState = .disconnected; operationResult = "Stopped worker recovered. Cache retained; reconnect to resume pending uploads."
                return
            }
            try await validateIdentity(loaded)
            let recoveredStats = try await authenticatedStats(loaded, requireObservedBinding: loaded.observedFS != nil)
            if loaded.observedFS == nil || loaded.observedCachePath == nil {
                loaded.observedFS = recoveredStats.fs; loaded.observedCachePath = recoveredStats.diskCache.path
            }
            // The mount helper can finish immediately before a crash or deadline. The authenticated
            // process and exact NFS port establish provenance before recording its new filesystem ID.
            if loaded.mountID == nil, let entry = MountInspector.exactEntry(at: loaded.mountPath, entries: entries) {
                guard entry.type == "nfs", entry.source == "127.0.0.1:/", try await mountUsesPort(loaded) else {
                    throw DriveError.message("Interrupted mount has different ownership. It was left intact.")
                }
                loaded.mountID = entry.id
            }
            record = loaded; try await offUI { try self.store.save(loaded) }
            mounted = try await ownedMount(loaded, entries: entries)
            apply(recoveredStats)
            if let pendingLaunch {
                try await offUI { try self.store.removeIntent(expectedSessionID: pendingLaunch.sessionID) }
            }
            running = true; recoveryRequired = false
            mountState = mounted ? .connected : .unmounted
            operationResult = mounted ? "Recovered the verified storage worker and Finder mount." : "Recovered the verified worker. Eject to drain and stop it before connecting again."
            beginPolling()
        }
    }

    func start() async {
        guard canConnect else { return }
        await perform { [self] in
            generation = UUID(); uploadProgress = nil; receipt = nil; uploads = .unknown; mountState = .checking
            if fixtureSource == nil { try connection.validate() }
            if useKeychain { try await Credentials.saveBounded(connection) }
            guard try await offUI({ try self.store.load() }) == nil,
                  try await offUI({ try self.store.loadIntent() }) == nil else {
                recoveryRequired = true
                throw DriveError.message("An existing worker record needs recovery. No second writer was started.")
            }
            guard MountInspector.exactEntry(at: mountpoint.path, entries: try MountInspector.snapshot()) == nil else {
                throw DriveError.message("Mount location is occupied. No volume was replaced.")
            }
            operationResult = "Checking the selected destination…"
            let check = try await command(["lsjson", remote, "--max-depth", "1", "--retries", "1", "--low-level-retries", "1", "--timeout", "10s"], timeout: 15)
            guard check.exitCode == 0 else { throw DriveError.message("Connection check failed. Check endpoint and bucket permissions. No mount was started.") }
            let prepared = try await fileOperation("prepare", base: mountpoint, name: "-", expected: "-")
            guard prepared.exitCode == 0 else { throw DriveError.message("Mount folder is occupied or unavailable. Preserve its local files before connecting.") }
            let cacheRoot = cache
            try await offUI {
                try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try Task.checkCancellation()
            let nfsPort = Int.random(in: 60000...65000), controlPort = Int.random(in: 49152...59999)
            let token = UUID().uuidString + UUID().uuidString
            let workerBinary = try await offUI { try WorkerExecutable.stage(self.binary, root: self.root) }
            let executableDigest = try await offUI { try Self.digest(workerBinary) }
            let p = Process(); p.executableURL = workerBinary
            p.arguments = ["serve", "nfs", remote, "--addr", "127.0.0.1:\(nfsPort)", "--config", "/dev/null",
                "--cache-dir", cache.path, "--vfs-write-back", "2s",
                "--vfs-read-chunk-size", "8M", "--vfs-read-chunk-size-limit", "32M",
                "--buffer-size", "4M", "--dir-cache-time", "30s", "--poll-interval", "0",
                "--transfers", "2", "--rc", "--rc-addr", "127.0.0.1:\(controlPort)"]
            p.arguments = (p.arguments ?? []) + CloudCachePolicy.arguments
            if fixtureSource == nil { p.arguments = (p.arguments ?? []) + ["--bwlimit", uploadLimit.controlRate] }
            if fixtureSource != nil, let limit = fixtureUploadLimitMiB, limit > 0 {
                p.arguments = (p.arguments ?? []) + ["--bwlimit", "\(limit)M"]
            }
            var environment = connection.workerEnvironment
            environment["RCLONE_RC_USER"] = "bucketdrive"; environment["RCLONE_RC_PASS"] = token
            p.environment = environment; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            let intent = LaunchIntent(sessionID: UUID(), executableSHA256: executableDigest,
                destinationFingerprint: connection.fingerprint, cachePath: cache.path,
                mountPath: mountpoint.path, nfsPort: nfsPort, controlPort: controlPort,
                controlToken: token, expectedRemote: remote)
            try Task.checkCancellation()
            try await offUI { try self.store.saveIntent(intent) }
            recoveryRequired = true
            do { try await offUI { try p.run() } }
            catch {
                // Launch failed before a worker existed. Retire only this exact pending intent.
                try await offUI { try self.store.removeIntent(expectedSessionID: intent.sessionID) }
                recoveryRequired = false
                throw error
            }
            worker = p; running = true
            let identity = try ProcessIdentity.capture(pid: p.processIdentifier)
            var owned = intent.record(process: identity)
            try await offUI {
                try owned.validate(binary: workerBinary, destinationFingerprint: self.connection.fingerprint, cachePath: self.cache.path, mountPath: self.mountpoint.path)
            }
            record = owned
            // Persistence failures retain the intent plus in-memory identity; no second writer can start.
            try await offUI { try self.store.save(owned) }
            try await offUI { try self.store.removeIntent(expectedSessionID: intent.sessionID) }
            operationResult = "Waiting for authenticated worker readiness…"
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            var stats: VFSStats?
            while ContinuousClock.now < readyDeadline {
                try Task.checkCancellation()
                guard owned.process.matchesRunningProcess() else { throw DriveError.message("Storage worker exited during startup. Cache retained.") }
                do { stats = try await authenticatedStats(owned, requireObservedBinding: false); break }
                catch { try await Task.sleep(nanoseconds: 150_000_000) }
            }
            guard let stats else { throw DriveError.message("Worker readiness could not be authenticated. No Finder mount was attempted; use Eject or Retry Recovery.") }
            guard CloudCachePolicy.isActive(stats.cacheOptions) else {
                throw DriveError.message("Automatic cache reclamation was not enabled by the worker. No Finder mount was started; Eject to stop this attempt.")
            }
            owned.observedFS = stats.fs; owned.observedCachePath = stats.diskCache.path
            record = owned; try await offUI { try self.store.save(owned) }
            try Task.checkCancellation()
            operationResult = "Mounting the verified worker in Finder…"
            var result: CommandResult?
            var mountError: Error?
            do {
                result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/mount_nfs"), arguments: ["-o", "port=\(nfsPort),mountport=\(nfsPort),tcp,vers=3,nolocks,nodev,nosuid,acregmin=0,acregmax=1", "127.0.0.1:/", mountpoint.path], timeout: 15))
            } catch { mountError = error }
            // Bind any observed mount to the worker's actual NFS port, not a generic source name.
            // Snapshot even after a failed command: never forget a mount that actually appeared.
            if let entry = MountInspector.exactEntry(at: mountpoint.path, entries: try MountInspector.snapshot()) {
                guard entry.source == "127.0.0.1:/", entry.type == "nfs" else { throw DriveError.message("An unexpected volume appeared. It was left intact.") }
                guard try await Task.detached(operation: { try await self.mountUsesPort(owned) }).value else { throw DriveError.message("The mounted NFS port does not belong to this session. Volume left intact.") }
                owned.mountID = entry.id; record = owned
                try await offUI { try self.store.save(owned) }
            }
            if let mountError { throw mountError }
            guard result?.exitCode == 0, try MountInspector.validateOwnedMount(record: owned, entries: MountInspector.snapshot()) else {
                throw DriveError.message("Finder mount did not complete. Worker/cache retained; use Eject or Retry Recovery.")
            }
            mounted = true; running = true; recoveryRequired = false; mountState = .connected
            operationResult = "Connected. Finder saves are local until uploaded."
            apply(stats); beginPolling()
            if fixtureSource == nil { openDrive() }
        }
    }

    func refresh() async {
        guard !busy, !pollingNow, let owned = record else { return }
        pollingNow = true; defer { pollingNow = false }
        let epoch = generation
        do {
            try await validateIdentity(owned)
            let stats = try await authenticatedStats(owned)
            let isMounted = try await ownedMount(owned, entries: MountInspector.snapshot())
            let sample = await sampleProgress(owned, stats: stats)
            guard epoch == generation, !busy else { return }
            mounted = isMounted; running = true; recoveryRequired = false
            mountState = isMounted ? .connected : .unmounted; apply(stats)
            applyProgress(sample)
        } catch {
            guard epoch == generation, !busy else { return }
            uploads = .unknown; uploadProgress = nil; detail = ""; activity = []; activityAvailable = false; mountState = .blocked; recoveryRequired = true
            if diagnostics.last?.category != "Ownership/status check" { log("Ownership/status check", "Unknown; no automatic action") }
            // Keep existing mount/record and expose an explicit recovery action.
            operationResult = "Worker or mount ownership could not be confirmed. No process or volume was changed. Retry Recovery."
        }
    }

    func eject() async {
        guard canEject else { return }
        await perform { [self] in
            generation = UUID(); uploadProgress = nil; polling?.cancel(); polling = nil; uploads = .unknown
            guard let owned = record else { return }
            try await validateIdentity(owned)
            _ = try await authenticatedStats(owned, requireObservedBinding: owned.observedFS != nil)
            if try await ownedMount(owned, entries: MountInspector.snapshot()) {
                operationResult = "Ejecting the owned Finder volume…"
                let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [owned.mountPath], timeout: 15))
                guard result.exitCode == 0 else { throw DriveError.message("Drive could not eject. Close its files/windows and retry; nothing was forced.") }
            }
            guard MountInspector.exactEntry(at: owned.mountPath, entries: try MountInspector.snapshot()) == nil else {
                throw DriveError.message("A volume is still mounted. Worker and cache retained.")
            }
            mounted = false; mountState = .unmounted
            operationResult = "Waiting for pending uploads to drain…"
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var idle = false
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let stats = try await authenticatedStats(owned, requireObservedBinding: owned.observedFS != nil)
                apply(stats)
                applyProgress(await sampleProgress(owned, stats: stats))
                if stats.diskCache.idle { idle = true; break }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            guard idle else { throw DriveError.message("Pending uploads or errors remain. Worker/cache retained. Retry Eject when uploads finish.") }
            try Task.checkCancellation()
            // Revalidate process start identity and authenticated PID immediately before signaling.
            try await validateIdentity(owned)
            guard try await client(owned).pid() == owned.process.pid,
                  owned.process.matchesRunningProcess() else { throw DriveError.message("Worker identity changed. No signal was sent.") }
            guard kill(owned.process.pid, SIGTERM) == 0 else { throw DriveError.message("Worker could not be stopped. Recovery record retained.") }
            operationResult = "Confirming storage worker exit…"
            let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while owned.process.matchesRunningProcess(), ContinuousClock.now < exitDeadline {
                // Once termination has begun, finish observation even if the UI cancels.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !owned.process.matchesRunningProcess() else { throw DriveError.message("Worker has not exited. Recovery record retained; reconnect is blocked.") }
            guard MountInspector.exactEntry(at: owned.mountPath, entries: try MountInspector.snapshot()) == nil else {
                throw DriveError.message("Unexpected mount after shutdown. Recovery record retained.")
            }
            try await offUI {
                if let pending = try self.store.loadIntent(), pending.sessionID == owned.sessionID {
                    try self.store.removeIntent(expectedSessionID: owned.sessionID)
                }
                try self.store.remove(expectedSessionID: owned.sessionID)
            }
            record = nil; worker = nil; running = false; mounted = false; recoveryRequired = false
            uploadProgress = nil; activity = []; activityAvailable = false
            mountState = .disconnected; uploads = .unknown; detail = ""
            operationResult = "Ejected and storage worker exit confirmed. Pending cache was not deleted."
        }
    }

    func verifyBucket() async {
        guard mounted, !busy, let owned = record else { return }
        await perform { [self] in
            try await validateIdentity(owned); _ = try await authenticatedStats(owned)
            guard try await ownedMount(owned, entries: MountInspector.snapshot()) else { throw DriveError.message("Owned Finder mount is absent.") }
            receipt = nil
            let name = "clouddrive-check-" + UUID().uuidString + ".bin"
            operationResult = "Verifying a disposable 1 MiB file. Cancellation retains the fixture if present."
            let write = try await fileOperation("write", base: mountpoint, name: name, expected: "-")
            guard write.exitCode == 0 else { throw DriveError.message("Fixture write failed. Preserve the file if present.") }
            let hashed = try await fileOperation("hash", base: mountpoint, name: name, expected: "-")
            let digest = String(decoding: hashed.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard hashed.exitCode == 0, digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw DriveError.message("Fixture could not be hashed. Retained for recovery.") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            var matched = false
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let download = try await command(["copyto", remote + "/" + name, root.appendingPathComponent(name).path, "--retries", "1", "--low-level-retries", "1", "--timeout", "5s"], timeout: 8)
                if download.exitCode == 0 {
                    let check = try await fileOperation("hash", base: root, name: name, expected: digest)
                    if check.exitCode == 0 { matched = true; break }
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            guard matched else { throw DriveError.message("Independent download did not verify within the deadline. Fixture retained.") }
            let verified = VerificationReceipt(destinationFingerprint: connection.fingerprint, fixture: name, byteCount: 1048576, sha256: digest, verifiedAt: Date())
            // Only exact synthetic fixture names and their checked bytes can be removed by the helper.
            let removed = try await fileOperation("remove", base: mountpoint, name: name, expected: digest)
            let localRemoved = try await fileOperation("remove", base: root, name: name, expected: digest)
            receipt = verified
            operationResult = removed.exitCode == 0 && localRemoved.exitCode == 0 ? "Independent R2 fixture verification passed; fixture cleanup requested." : "Verification passed. A test fixture could not be removed; it was retained."
        }
    }

    private var remote: String { fixtureSource?.path ?? connection.remote }
    private func mountUsesPort(_ owned: WorkerRecord) async throws -> Bool {
        let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/nfsstat"), arguments: ["-m"], timeout: 3, outputLimit: 262144))
        guard result.exitCode == 0, !result.outputTruncated else { throw DriveError.message("Mount port could not be inspected. Volume left intact.") }
        return NFSProvenance.matches(report: String(decoding: result.output, as: UTF8.self), mountPath: owned.mountPath, port: owned.nfsPort)
    }
    private func ownedMount(_ owned: WorkerRecord, entries: [MountEntry]) async throws -> Bool {
        guard try MountInspector.validateOwnedMount(record: owned, entries: entries) else { return false }
        guard try await mountUsesPort(owned) else { throw DriveError.message("Mounted port differs from the recorded worker. Volume left intact.") }
        return true
    }
    private func client(_ owned: WorkerRecord) -> ControlClient { ControlClient(port: owned.controlPort, token: owned.controlToken) }
    private func validateIdentity(_ owned: WorkerRecord) async throws {
        try await offUI { try owned.validateSession(destinationFingerprint: self.connection.fingerprint, cachePath: self.cache.path, mountPath: self.mountpoint.path) }
        guard owned.expectedRemote == remote else { throw DriveError.message("Worker destination differs from this connection. It was left intact.") }
    }
    private func authenticatedStats(_ owned: WorkerRecord, requireObservedBinding: Bool = true) async throws -> VFSStats {
        guard owned.process.matchesRunningProcess(), try await client(owned).pid() == owned.process.pid else {
            throw DriveError.message("The control endpoint does not belong to the recorded worker.")
        }
        let stats = try await client(owned).stats()
        let bindingMatches: Bool
        if let source = fixtureSource {
            bindingMatches = stats.fs == source.path && stats.diskCache.path.hasPrefix(cache.appendingPathComponent("vfs/local/").path)
        } else { bindingMatches = BackendBinding.matches(fs: stats.fs, cachePath: stats.diskCache.path, connection: connection, cacheRoot: cache) }
        guard bindingMatches else { throw DriveError.message("Worker cache or remote does not match this destination.") }
        if requireObservedBinding {
            guard owned.observedFS == stats.fs, owned.observedCachePath == stats.diskCache.path else { throw DriveError.message("Worker binding was not recorded or changed. No action was taken.") }
        }
        return stats
    }
    private struct ProgressSample {
        let queue: UploadQueue?
        let snapshot: UploadProgressSnapshot?
        let uploadLimit: UploadLimit?
        let sessionID: UUID
    }
    private func sampleProgress(_ owned: WorkerRecord, stats: VFSStats) async -> ProgressSample {
        let control = client(owned)
        async let queueData = try? control.call(route: "vfs/queue")
        async let transferData = try? control.call(route: "core/stats")
        async let limit = try? control.uploadLimit()
        let queue = await queueData.flatMap { try? UploadQueue.decode($0) }
        let transfers = await transferData.flatMap { try? TransferStats.decode($0) }
        let snapshot: UploadProgressSnapshot?
        if let queue, let transfers { snapshot = UploadProgressSnapshot.make(queue: queue, stats: transfers, destination: stats.fs) }
        else { snapshot = nil }
        return await ProgressSample(queue: queue, snapshot: snapshot, uploadLimit: limit, sessionID: owned.sessionID)
    }
    private func applyProgress(_ sample: ProgressSample) {
        activity = Array(sample.queue?.queue.prefix(50) ?? [].prefix(50))
        activityAvailable = sample.queue != nil
        activitySessionID = sample.queue == nil ? nil : sample.sessionID
        uploadProgress = sample.snapshot
        uploadSampledAt = sample.snapshot == nil ? nil : Date()
        appliedUploadLimit = sample.uploadLimit
    }
    var storagePolicyText: String {
        if running && !automaticSpaceSaving { return "This worker needs a reconnect to enable automatic space saving." }
        return "Uploaded files automatically release temporary local space after use. Open them to stream from R2."
    }
    var uploadIssue: String? {
        switch uploads {
        case .failed, .outOfSpace: return uploads.text
        case .unknown: return running ? uploads.text : nil
        default: return nil
        }
    }
    private func apply(_ stats: VFSStats) {
        automaticSpaceSaving = CloudCachePolicy.isActive(stats.cacheOptions)
        let d = stats.diskCache
        uploads = d.outOfSpace ? .outOfSpace : d.erroredFiles > 0 ? .failed(d.erroredFiles) : (d.uploadsQueued > 0 || d.uploadsInProgress > 0) ? .active(queued: d.uploadsQueued, uploading: d.uploadsInProgress) : .idle
        detail = "\(ByteCountFormatter.string(fromByteCount: d.bytesUsed, countStyle: .file)) temporary file cache reported; metadata and other app storage are separate."
    }
    private func beginPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        lastOperationFailed = false
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await body() }
            catch {
                self.lastOperationFailed = true
                self.uploads = .unknown; self.uploadProgress = nil; self.activityAvailable = false
                self.operationResult = self.safeMessage(error)
                if self.record != nil || self.recoveryRequired { self.mountState = .blocked; self.recoveryRequired = true }
                else { self.mountState = .disconnected }
            }
            self.log("Operation completed", self.mountState == .blocked ? "Needs recovery; state retained" : "Returned control")
            self.busy = false; self.operation = nil
            if self.record != nil { self.beginPolling() }
        }
        operation = task
        await task.value
    }
    private func log(_ category: String, _ outcome: String) {
        // Fixed categories only. Never persist raw provider/process output or filenames.
        diagnostics.append(DiagnosticEvent(category: category, outcome: outcome))
        if diagnostics.count > 50 { diagnostics.removeFirst(diagnostics.count - 50) }
    }
    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "Operation cancelled. Worker/cache state retained. Retry Recovery before reconnecting." }
        if let e = error as? DriveError { return e.localizedDescription }
        if let e = error as? RuntimeFailure { return e.localizedDescription }
        if let e = error as? OwnershipError { return e.localizedDescription }
        if let e = error as? CredentialFailure { return e.localizedDescription }
        return "Operation could not be confirmed. Worker/cache state retained. Retry Recovery; no automatic cleanup was performed."
    }
    private func command(_ args: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await CommandRunner.run(CommandSpec(executable: binary, arguments: args + ["--config", "/dev/null"], environment: connection.workerEnvironment, timeout: timeout, outputLimit: 0))
    }
    private func fileOperation(_ action: String, base: URL, name: String, expected: String) async throws -> CommandResult {
        try await CommandRunner.run(CommandSpec(executable: helper, arguments: [action, base.path, name, expected], timeout: 8, outputLimit: 256))
    }
    private func offUI<T>(_ body: @escaping () throws -> T) async throws -> T { try await Task.detached(priority: .utility) { try body() }.value }
    private static func digest(_ url: URL) throws -> String {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var h = SHA256()
        while let chunk = try f.read(upToCount: 1024 * 1024), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #if DEBUG
    // Simulate controller loss while leaving the real synthetic storage worker alive.
    func relinquishForTesting() {
        polling?.cancel(); polling = nil; ownerLock = nil
    }
    #endif
}
