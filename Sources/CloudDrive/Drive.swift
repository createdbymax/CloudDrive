import AppKit
import CryptoKit
import Foundation
import Darwin
import Combine

@MainActor final class Drive: ObservableObject {
    @Published var connection = Connection() {
        didSet {
            if oldValue.fingerprint != connection.fingerprint {
                receipt = nil; uploadProgress = nil; storageSnapshot = nil
                moveRecordsChecked = false; finderMoves = nil; moveSampledAt = nil
                Task { await refreshMoveRecords() }
            }
            catalogController?.configure(connection: connection)
            namespaceController?.configure(connection)
            if catalogController?.automaticEnabled == true { directUploads.requestCatalogDelivery() }
        }
    }
    @Published private(set) var finderMoves: FinderMoveStatus?
    @Published private(set) var moveSampledAt: Date?
    @Published private(set) var moveRecordsPending = false
    @Published private(set) var moveRecordsChecked = false
    @Published private(set) var movesExpected = false
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
    private var namespaceController: NamespaceDriveController?
    private var namespaceObservation: AnyCancellable?
    var namespaceEngine: NamespaceDriveController {
        if let namespaceController { return namespaceController }
        let controller = NamespaceDriveController(root: root)
        controller.configure(connection)
        controller.uploadRate = { [weak self] in self?.uploadLimit.bytesPerSecond ?? -1 }
        controller.legacySafetyCheck = { [weak self] in self?.canAdoptNamespace == true }
        controller.onRevision = { [weak self] _ in self?.catalogController?.namespaceChanged() }
        namespaceObservation = controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        namespaceController = controller
        return controller
    }
    var finderMounted: Bool { mounted || namespaceEngine.mounted }
    var storageWorkerRunning: Bool { running || namespaceEngine.running }
    var operationBusy: Bool { busy || namespaceEngine.busy }
    var browsingMountpoint: URL { namespaceEngine.ownsDestination ? namespaceEngine.mountpoint : mountpoint }
    private var dropWorkerProof: (session: UUID, exclusive: Bool, time: Date)?
    var canAcceptMountedDrop: Bool {
        guard !operationBusy else { return false }
        if namespaceEngine.ownsDestination {
            return namespaceEngine.mounted && namespaceEngine.running && !namespaceEngine.readOnly
        }
        guard mounted, running, mountState == .connected, let record,
              record.destinationFingerprint == connection.fingerprint,
              let proof = dropWorkerProof, proof.session == record.sessionID else { return false }
        return proof.exclusive && UploadFreshness.isFresh(proof.time, at: Date())
    }
    func dropMount() throws -> MountEntry {
        guard canAcceptMountedDrop else {
            throw DriveError.message("Connect a writable drive using the updated CloudDrive worker, then try adding your files again.")
        }
        if namespaceEngine.ownsDestination { return try namespaceEngine.dropMount() }
        let entries = try MountInspector.snapshot()
        guard mounted, running, mountState == .connected, let record,
              record.destinationFingerprint == connection.fingerprint,
              try MountInspector.validateOwnedMount(record: record, entries: entries),
              let entry = MountInspector.exactEntry(at: record.mountPath, entries: entries)
        else { throw POSIXError(.ENOTCONN) }
        return entry
    }
    var canAdoptNamespace: Bool {
        !busy && ownerLock != nil && record == nil && !recoveryRequired && !mounted && !running &&
        moveRecordsChecked && !moveRecordsPending && !directUploads.holdsDestination
    }
    private var ownerLock: OwnerLock?
    private var recoveryRequired = true
    private var polling: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var pollingNow = false
    private var detachObservation: (session: UUID, since: ContinuousClock.Instant, latest: ContinuousClock.Instant)?
    private var failedDetachProbe: UUID?
    private var storageScanning = false
    private var directObservation: AnyCancellable?
    private let fixtureSource: URL?
    private let fixtureUploadLimitMiB: Int?
    private let useKeychain: Bool
    let root: URL
    let binary: URL
    let helper: URL
    private var catalogController: CatalogController?
    var catalog: CatalogController {
        if let catalogController { return catalogController }
        let controller = CatalogController(root: root)
        catalogController = controller
        controller.configure(connection: connection)
        controller.namespaceSearch = { [weak self] query in
            guard let self, self.namespaceEngine.enabled else { return nil }
            return try await self.namespaceEngine.search(query)
        }
        return controller
    }
    lazy var directUploads: DirectUploadController = {
        let controller = DirectUploadController(defaultDirectory: root.appendingPathComponent("DirectUploads"), rememberLocation: useKeychain)
        controller.canStart = { [weak self] in self?.canDirectUpload == true }
        controller.namespaceEnqueue = { [weak self] urls, connection in
            guard let self, self.namespaceEngine.ownsDestination else { return false }
            guard self.namespaceEngine.enabled, !self.namespaceEngine.readOnly, !self.namespaceEngine.busy,
                  self.connection.fingerprint == connection.fingerprint else { throw DriveError.message("The new drive is not ready to accept these files. Finish setup or recovery first.") }
            await self.namespaceEngine.enqueue(urls)
            if !self.namespaceEngine.error.isEmpty { throw DriveError.message(self.namespaceEngine.error) }
            return true
        }
        controller.uploadRate = { [weak self] in self?.uploadLimit.bytesPerSecond ?? -1 }
        controller.catalogDestination = { [weak self] in self?.connection.fingerprint }
        controller.catalogDelivery = { [weak self] hints in
            guard let self else { throw CatalogFailure.superseded }
            try await self.catalog.recordUploadHints(hints)
        }
        directObservation = controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return controller
    }()
    var mountpoint: URL { root.appendingPathComponent("Drive", isDirectory: true) }
    private var legacyCache: URL { root.appendingPathComponent("Cache/" + connection.fingerprint) }
    var cache: URL {
        let versioned = CloudCachePolicy.writebackCache(beside: legacyCache)
        if fixtureSource == nil, FileManager.default.fileExists(atPath: versioned.path) { return versioned }
        return legacyCache
    }
    private var store: WorkerRecordStore { get throws { try WorkerRecordStore(directory: root) } }
    var status: String { mountState.text }
    var uploadStatus: String { uploads.text }
    var verification: String { receipt?.destinationFingerprint == connection.fingerprint ? receipt?.text ?? "" : "" }
    private var canStartWriter: Bool { !busy && ownerLock != nil && record == nil && !recoveryRequired && !mounted && !namespaceEngine.ownsDestination }
    var canDirectUpload: Bool { canStartWriter && moveRecordsChecked && !moveRecordsPending }
    var canConnect: Bool { namespaceEngine.enabled ? (!operationBusy && !namespaceEngine.mounted && namespaceEngine.extensionAvailable) : (canStartWriter && !directUploads.holdsDestination) }
    var canEject: Bool { !operationBusy && (record != nil || namespaceEngine.hasSession) }
    var ejectActionTitle: String { finderMounted ? "Eject Finder drive" : "Check remaining cloud work" }
    var canQuit: Bool { !operationBusy && record == nil && !mounted && directUploads.canQuit && namespaceEngine.canQuit }

    init(root: URL? = nil, binary: URL? = nil, helper: URL? = nil, fixtureSource: URL? = nil, fixtureUploadLimitMiB: Int? = nil, useKeychain: Bool = true, autoRecover: Bool = true) {
        // Keep the existing state/lock/cache namespace across the CloudDrive rename.
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BucketDrive")
        self.binary = binary ?? Bundle.main.resourceURL!.appendingPathComponent("rclone")
        self.helper = helper ?? Bundle.main.resourceURL!.appendingPathComponent("CloudDriveHelper")
        self.fixtureSource = fixtureSource
        self.fixtureUploadLimitMiB = fixtureUploadLimitMiB
        self.useKeychain = useKeychain
        if useKeychain { self.uploadLimit = UploadLimit(rawValue: UserDefaults.standard.integer(forKey: "uploadLimitMbps")) ?? .unlimited }
        if autoRecover { Task { [weak self] in await self?.recover(connectSavedDrive: true) } }
    }
    deinit { polling?.cancel(); operation?.cancel() }
    func openDrive() { if finderMounted { NSWorkspace.shared.open(browsingMountpoint) } }
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
    var moveDirectory: URL { root.appendingPathComponent("Moves/" + connection.fingerprint) }
    func refreshMoveRecords() async {
        let fingerprint = connection.fingerprint, directory = moveDirectory
        let pending = (try? await Task.detached { try FinderMoveRecords.pending(in: directory, expectedBinding: fingerprint) }.value) ?? true
        guard connection.fingerprint == fingerprint else { return }
        moveRecordsPending = pending; moveRecordsChecked = true
    }
    var canResumeMove: Bool {
        guard !busy, running, let moves = finderMoves, UploadFreshness.isFresh(moveSampledAt, at: Date()) else { return false }
        return moves.jobs == nil ? moves.needsRecovery && moves.phase == .needsRecovery : !moves.recoverableJobs.isEmpty
    }
    func resumeMove(id: String? = nil) async {
        guard canResumeMove, let owned = record, let sample = finderMoves else { return }
        // A worker with job reporting requires an explicit choice from its fresh
        // snapshot. Never degrade a stale job-specific request to legacy resume.
        guard let body = sample.resumeBody(id: id) else { return }
        await perform { [self] in
            try await validateIdentity(owned)
            _ = try await authenticatedStats(owned)
            let current = try await readFinderMoveStatus(owned)
            guard current.resumeBody(id: id) != nil else { throw DriveError.message("Move status changed. Review the current moves before resuming.") }
            finderMoves = try FinderMoveStatus.decode(await client(owned).call(route: "vfs/moves", body: body))
            moveSampledAt = Date(); moveRecordsPending = true
            operationResult = "Move recovery requested. Keep CloudDrive running until it finishes."
        }
    }
    #if DEBUG
    var finderMoveStatusForTesting: (() throws -> FinderMoveStatus)?
    #endif
    private func readFinderMoveStatus(_ owned: WorkerRecord) async throws -> FinderMoveStatus {
        #if DEBUG
        if fixtureSource != nil, !useKeychain, let sample = finderMoveStatusForTesting { return try sample() }
        #endif
        return try FinderMoveStatus.decode(await client(owned).call(route: "vfs/moves"))
    }
    private func moveStatusBeforeStop(_ owned: WorkerRecord, stats: VFSStats) async throws -> FinderMoveStatus? {
        do {
            let value = try await readFinderMoveStatus(owned)
            guard value.enabled || stats.cacheOptions?.moveJournal?.isEmpty != false else { throw RuntimeFailure.invalidControlResponse }
            finderMoves = value; moveSampledAt = Date()
            if !value.holdsWorker { try await confirmMoveJournalsClear() }
            return value.enabled ? value : nil
        } catch RuntimeFailure.controlHTTP(404) where stats.cacheOptions?.moveJournal?.isEmpty != false {
            try await confirmMoveJournalsClear()
            return nil // Older workers without retained journals use the normal drain path.
        }
    }
    private func confirmMoveJournalsClear() async throws {
        let binding = connection.fingerprint, directory = moveDirectory
        let pending = try await Task.detached(priority: .utility) {
            try FinderMoveRecords.pending(in: directory, expectedBinding: binding)
        }.value
        guard !pending else {
            moveRecordsPending = true
            throw DriveError.message("A saved Finder move still needs recovery. Review the moves before stopping this worker.")
        }
    }
    var movePickerSession: UUID? {
        guard mounted, running, !operationBusy, !recoveryRequired, finderMoves?.jobs != nil,
              !namespaceEngine.ownsDestination else { return nil }
        return record?.sessionID
    }

    func chooseDestinationAndMove(source: URL, session: UUID) async {
        let folder = NSOpenPanel()
        folder.title = "Choose a destination folder"
        folder.message = "Move the item at “\(source.path)” into the folder you choose."
        folder.prompt = "Move Here"
        folder.canChooseDirectories = true
        folder.canChooseFiles = false
        folder.canCreateDirectories = false
        folder.directoryURL = mountpoint
        guard await folder.begin() == .OK, let destination = folder.url else { return }
        await submitMove(source: source, destinationFolder: destination, session: session)
    }

    func submitMove(source: URL, destinationFolder: URL, session: UUID) async {
        guard session == movePickerSession, let owned = record else {
            lastOperationFailed = true
            operationResult = "The drive connection changed. Select the items again."
            return
        }
        await perform { [self] in
            try await validateIdentity(owned)
            _ = try await authenticatedStats(owned)
            guard try await ownedMount(owned, entries: MountInspector.snapshot()) else {
                throw DriveError.message("Reconnect the drive before moving an item.")
            }
            // Errors in a single rename do not invalidate the mounted drive.
            do {
                @MainActor func submit(name: String? = nil) async throws -> DriveMoveRequest.Receipt {
                    let request = try DriveMoveRequest(source: source, folder: destinationFolder, under: mountpoint, name: name)
                    let data = try await client(owned).call(route: "vfs/move", body: JSONEncoder().encode(request))
                    return try JSONDecoder().decode(DriveMoveRequest.Receipt.self, from: data)
                }
                var reply = try await submit()
                if !reply.accepted, reply.reason == "destinationExists" {
                    let alert = NSAlert()
                    alert.messageText = "“\(source.lastPathComponent)” already exists here"
                    alert.informativeText = "To keep both items, enter a name for the incoming item."
                    let original = source.lastPathComponent as NSString
                    let suffix = original.pathExtension.isEmpty ? "" : "." + original.pathExtension
                    let name = NSTextField(string: original.deletingPathExtension + " (2)" + suffix)
                    name.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
                    name.setAccessibilityLabel("Name for incoming item")
                    alert.accessoryView = name
                    alert.addButton(withTitle: "Keep Both")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    try await validateIdentity(owned)
                    _ = try await authenticatedStats(owned)
                    reply = try await submit(name: name.stringValue)
                }
                guard reply.accepted, reply.id?.isEmpty == false else {
                    if reply.reason == "destinationExists" { throw DriveError.message("That name is already in use. Choose a different name.") }
                    if reply.reason == "busy" { throw DriveError.message("A move is using this path, or all four moves are busy. Check Finder moves and try again.") }
                    throw RuntimeFailure.invalidControlResponse
                }
                moveRecordsPending = true
                operationResult = "Move submitted. Its progress appears under Finder moves."
            } catch let error as DriveError {
                lastOperationFailed = true
                operationResult = error.localizedDescription
            } catch {
                lastOperationFailed = true
                operationResult = "Check Finder moves before retrying. A destination with the same name, an overlapping move, or four busy moves can prevent a new move."
            }
            if let status = try? await readFinderMoveStatus(owned) {
                finderMoves = status
                moveSampledAt = Date()
            }
        }
    }

    func cancelOperation() { operation?.cancel() }
    func changeUploadLimit(_ requested: UploadLimit) async {
        guard !operationBusy else { return }
        if namespaceEngine.ownsDestination {
            guard namespaceEngine.running else { return }
            let applied = await namespaceEngine.setUploadRate(requested.bytesPerSecond)
            lastOperationFailed = !applied
            guard applied else { operationResult = namespaceEngine.error.isEmpty ? "The upload limit could not be confirmed. Your previous saved limit was retained." : namespaceEngine.error; return }
            uploadLimit = requested
            if useKeychain { UserDefaults.standard.set(requested.rawValue, forKey: "uploadLimitMbps") }
            operationResult = "Upload limit applied and checked: \(requested.label). Downloads remain unlimited."
            return
        }
        guard !recoveryRequired else { return }
        await perform { [self] in
            appliedUploadLimit = nil
            if let owned = record {
                try await validateIdentity(owned)
                _ = try await authenticatedStats(owned)
                appliedUploadLimit = try await client(owned).setUploadLimit(requested)
            }
            uploadLimit = requested
            if useKeychain { UserDefaults.standard.set(requested.rawValue, forKey: "uploadLimitMbps") }
            operationResult = record == nil ? "Upload limit saved for the next direct-upload Resume or Finder connection. Downloads remain unlimited." : "Upload limit applied and checked: \(requested.label). Downloads remain unlimited."
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

    func recover(connectSavedDrive: Bool = false) async {
        await directUploads.restoreIfNeeded()
        var loadedSavedConnection = false
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
                    if let saved = try await Credentials.loadBounded() {
                        connection = saved; keychainNeedsApproval = false
                        loadedSavedConnection = true
                    }
                } catch {
                    keychainNeedsApproval = true
                    operationResult = safeMessage(error)
                }
            }
            await refreshMoveRecords()
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
                    // With a dead NFS server, macOS can take more than ten seconds
                    // to retire the mount. Keep the record until the command and
                    // the mount table both confirm the normal eject.
                    let unmount = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [loaded.mountPath], timeout: 45))
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
                await refreshMoveRecords()
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
            operationResult = mounted ? "Recovered the verified storage worker and Finder mount." : "Finder is ejected. Checking remaining cloud work in the background…"
            beginPolling()
        }
        // Startup first adopts any existing worker. Only a saved destination and
        // successful recovery may start a new one; an empty setup stays idle.
        if connectSavedDrive && loadedSavedConnection && !lastOperationFailed && canConnect {
            await start()
        }
        if namespaceEngine.ownsDestination && record == nil && !running && !mounted { await namespaceEngine.recover() }
    }

    /// One writer owns the bucket at every step. Existing plain R2 objects
    /// become verified backing locators when the initial index is published.
    func connectIndexedDrive() async {
        guard !operationBusy else { return }
        guard canAdoptNamespace, !namespaceEngine.capabilityBlocked else {
            lastOperationFailed = true
            operationResult = "Finish any pending transfers and eject the previous drive before connecting the indexed drive."
            return
        }
        let selected = connection
        let engine = namespaceEngine
        guard engine.extensionAvailable else {
            operationResult = "The native Finder extension is required to connect this drive."
            lastOperationFailed = true
            return
        }
        do {
            try selected.validate()
            if useKeychain { try await Credentials.saveBounded(selected) }
        } catch { lastOperationFailed = true; operationResult = safeMessage(error); return }
        lastOperationFailed = false
        operationResult = "Connecting to the drive…"
        defer {
            if !engine.error.isEmpty { operationResult = engine.error; lastOperationFailed = true }
            else if engine.mounted { operationResult = "Your drive is ready in Finder." }
            else { operationResult = "Setup has not finished. Open File Management to review the drive."; lastOperationFailed = true }
        }
        if !engine.hasSession && !engine.enabled {
            await engine.prepare(connection: selected, mode: .managed, legacySafe: canAdoptNamespace)
        } else if !engine.running { await engine.recover() }
        guard connection.fingerprint == selected.fingerprint, engine.running, engine.mode == .managed,
              engine.error.isEmpty else { return }
        if engine.importProgress?.complete != true {
            operationResult = "Reading file names and sizes from R2…"
            await engine.importMetadata()
        }
        guard engine.importProgress?.complete == true, engine.error.isEmpty else { return }
        if !engine.enabled {
            operationResult = "Saving the drive index to R2…"
            await engine.enableWrites()
        }
        if engine.enabled && !engine.readOnly && !engine.mounted && engine.error.isEmpty { await engine.mount() }
    }

    func start() async {
        if namespaceEngine.enabled {
            await namespaceEngine.recover()
            await namespaceEngine.mount()
            return
        }
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
            let originalCache = legacyCache
            let usesWriteback = fixtureSource == nil
            let cacheRoot = try await offUI {
                if usesWriteback { return try CloudCachePolicy.prepareWritebackCache(legacy: originalCache) }
                try FileManager.default.createDirectory(at: originalCache, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                return originalCache
            }
            try Task.checkCancellation()
            let nfsPort = Int.random(in: 60000...65000), controlPort = Int.random(in: 49152...59999)
            let token = UUID().uuidString + UUID().uuidString
            let workerBinary = try await offUI { try WorkerExecutable.stage(self.binary, root: self.root) }
            let executableDigest = try await offUI { try Self.digest(workerBinary) }
            let p = Process(); p.executableURL = workerBinary
            p.arguments = ["serve", "nfs", remote, "--addr", "127.0.0.1:\(nfsPort)", "--config", "/dev/null",
                "--cache-dir", cacheRoot.path, "--vfs-write-back", "2s",
                "--vfs-move-journal", moveDirectory.path, "--vfs-move-binding", connection.fingerprint,
                "--vfs-read-chunk-size", "8M", "--vfs-read-chunk-size-limit", "32M",
                "--buffer-size", "4M", "--dir-cache-time", "30s", "--poll-interval", "0",
                "--transfers", "2", "--rc", "--rc-addr", "127.0.0.1:\(controlPort)"]
            p.arguments = (p.arguments ?? []) + CloudCachePolicy.arguments
            if fixtureSource == nil {
                let writeback = try CloudCachePolicy.writebackArguments(for: connection, cache: cacheRoot)
                p.arguments = (p.arguments ?? []) + writeback + ["--bwlimit", uploadLimit.controlRate]
            }
            if fixtureSource != nil, let limit = fixtureUploadLimitMiB, limit > 0 {
                p.arguments = (p.arguments ?? []) + ["--bwlimit", "\(limit)M"]
            }
            var environment = connection.workerEnvironment
            environment["RCLONE_S3_DIRECTORY_MARKERS"] = "true"
            environment["RCLONE_RC_USER"] = "bucketdrive"; environment["RCLONE_RC_PASS"] = token
            p.environment = environment; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            let intent = LaunchIntent(sessionID: UUID(), executableSHA256: executableDigest,
                destinationFingerprint: connection.fingerprint, cachePath: cacheRoot.path,
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
            // Reopening a large durable range index or verifying the R2 namespace can take time.
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(usesWriteback ? 120 : 10))
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
            if usesWriteback {
                guard stats.cacheOptions?.spillPrefix == ".clouddrive-spill-" + connection.fingerprint,
                      let window = stats.cacheOptions?.spillWindow, window >= 8 * 1_048_576,
                      window <= 256 * 1_048_576 else {
                    throw DriveError.message("The worker could not confirm its R2 writeback configuration. Cache retained for recovery.")
                }
            }
            owned.observedFS = stats.fs; owned.observedCachePath = stats.diskCache.path
            record = owned; try await offUI { try self.store.save(owned) }
            try Task.checkCancellation()
            operationResult = "Mounting the verified worker in Finder…"
            var result: CommandResult?
            var mountError: Error?
            do {
                result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/mount_nfs"), arguments: ["-o", "port=\(nfsPort),mountport=\(nfsPort),tcp,vers=3,rsize=262144,wsize=262144,nolocks,mutejukebox,nodev,nosuid,acregmin=0,acregmax=1", "127.0.0.1:/", mountpoint.path], timeout: 15))
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
            operationResult = "Connected. Finder changes appear in Transfers until publication finishes."
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
            if isMounted {
                detachObservation = nil
                if owned.appDetachConfirmed == true {
                    var current = owned; current.appDetachConfirmed = false
                    record = current; try store.save(current)
                }
            }
            mounted = isMounted; running = true; recoveryRequired = false
            mountState = isMounted ? .connected : .unmounted; apply(stats)
            applyProgress(sample)
            if let catalog = catalogController, catalog.automaticEnabled {
                // Metadata feed failure never changes worker ownership or upload status.
                do {
                    let fingerprint = connection.fingerprint
                    let cursor = try await catalog.workerCursor()
                    let body = try JSONSerialization.data(withJSONObject:["after":cursor.sequence,"limit":256])
                    let changes = try await client(owned).call(route:"vfs/metadata-changes",body:body)
                    guard epoch == generation, !busy, connection.fingerprint == fingerprint, owned.destinationFingerprint == fingerprint, catalogController === catalog else { return }
                    try await catalog.recordWorkerChanges(changes,after:cursor.sequence)
                } catch { /* Older workers and feed gaps are covered by automatic reconciliation. */ }
            }
            if !isMounted {
                if owned.appDetachUncertain == true {
                    operationResult = "Finder eject was interrupted or busy. Close open files, then retry Eject. The worker is still running."
                } else if try await detachAllowsDrain(owned) {
                    await finishDetachedIfReady(owned, sampledStats: stats, sample: sample, epoch: epoch)
                } else {
                    operationResult = "Checking whether Finder finished ejecting. The worker is still running."
                }
            }
        } catch {
            guard epoch == generation, !busy else { return }
            detachObservation = nil
            uploads = .unknown; uploadProgress = nil; detail = ""; activity = []; activityAvailable = false; mountState = .blocked; recoveryRequired = true
            if diagnostics.last?.category != "Ownership/status check" { log("Ownership/status check", "Unknown; no automatic action") }
            // Keep existing mount/record and expose an explicit recovery action.
            operationResult = "Worker or mount ownership could not be confirmed. No process or volume was changed. Retry Recovery."
        }
    }

    func eject() async {
        if record == nil && namespaceEngine.hasSession { await namespaceEngine.eject(); return }
        guard canEject else { return }
        await perform { [self] in
            generation = UUID(); polling?.cancel(); polling = nil
            guard var owned = record else { return }
            failedDetachProbe = nil
            try await validateIdentity(owned)
            _ = try await authenticatedStats(owned, requireObservedBinding: owned.observedFS != nil)
            if try await ownedMount(owned, entries: MountInspector.snapshot()) {
                // Persist the uncertainty before handing control to the OS. A
                // failed unmount can hide its mount temporarily and then return.
                owned.appDetachConfirmed = false; owned.appDetachUncertain = true
                record = owned; detachObservation = nil; try store.save(owned)
                operationResult = "Ejecting the owned Finder volume…"
                let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [owned.mountPath], timeout: 15))
                guard result.exitCode == 0 else { throw DriveError.message("Drive could not eject. Close its files/windows and retry; nothing was forced.") }
            } else if owned.appDetachConfirmed != true {
                // Independent Finder eject: allow explicit verification of an
                // already absent mount, including after relaunch or busy eject.
                guard try await localMountDirectoryVisible(owned) else { throw DriveError.message("Finder eject is still uncertain. The worker and recovery record were retained.") }
                try await Task.sleep(for: .seconds(2))
            }
            guard try await localMountDirectoryVisible(owned) else {
                throw DriveError.message("A Finder mount may still be active. Worker and recovery record retained.")
            }
            owned.appDetachConfirmed = true; owned.appDetachUncertain = false
            try store.save(owned); record = owned
            mounted = false; running = true; mountState = .unmounted; recoveryRequired = false
            let stats = try await authenticatedStats(owned, requireObservedBinding: owned.observedFS != nil)
            apply(stats); applyProgress(await sampleProgress(owned, stats: stats))
            let moves = try await moveStatusBeforeStop(owned, stats: stats)
            if stats.diskCache.idle && (moves?.safeToStop ?? true) {
                try await finishDetachedWorker(owned)
            } else {
                updateDetachedMessage(stats: stats)
            }
        }
    }

    /// Detaching Finder does not cancel accepted cloud work or impose a drain deadline.
    private func updateDetachedMessage(stats: VFSStats) {
        lastOperationFailed = false
        if let moves = finderMoves, UploadFreshness.isFresh(moveSampledAt, at: Date()) {
            if moves.hasRecoverableJobs {
                operationResult = "Finder ejected. A cloud move needs attention. Choose Resume move before the worker can stop."
                return
            }
            if moves.hasActiveJobs {
                operationResult = "Finder ejected. Finishing the cloud move in the background. Keep CloudDrive running."
                return
            }
        }
        if stats.diskCache.erroredFiles > 0 || stats.diskCache.outOfSpace {
            operationResult = "Finder ejected. Pending files need attention before the worker can stop."
        } else if !stats.diskCache.idle {
            operationResult = "Finder ejected. Finishing uploads in the background. Keep CloudDrive running."
        } else if movesExpected && finderMoves == nil {
            operationResult = "Finder ejected. Cloud work status is unavailable. Worker and records were retained."
        } else {
            operationResult = "Finder ejected. Checking remaining cloud work…"
        }
    }

    private func detachAllowsDrain(_ owned: WorkerRecord) async throws -> Bool {
        guard owned.appDetachUncertain != true else { return false }
        if owned.appDetachConfirmed == true { return true }
        guard try await localMountDirectoryVisible(owned) else { detachObservation = nil; return false }
        let now = ContinuousClock.now
        if let observed = detachObservation, observed.session == owned.sessionID, observed.latest.duration(to: now) < .seconds(5) {
            detachObservation = (owned.sessionID, observed.since, now)
            return observed.since.duration(to: now) >= .seconds(6)
        }
        detachObservation = (owned.sessionID, now, now)
        return false
    }

    /// Confirm that both the kernel and NFS client have dropped this mount,
    /// and that the path resolves to a directory on its local parent's device.
    /// A potentially stale path is probed in a bounded subprocess. After a
    /// timeout we wait for explicit retry instead of spawning more probes.
    private func localMountDirectoryVisible(_ owned: WorkerRecord) async throws -> Bool {
        guard failedDetachProbe != owned.sessionID,
              MountInspector.exactEntry(at: owned.mountPath, entries: try MountInspector.snapshot()) == nil else { return false }
        do {
            let nfs = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/nfsstat"), arguments: ["-m"], timeout: 3, outputLimit: 262144))
            let report = String(decoding: nfs.output, as: UTF8.self)
            guard nfs.exitCode == 0, !nfs.outputTruncated, !report.localizedCaseInsensitiveContains("not responding"), !report.contains(owned.mountPath + " from "),
                  !report.contains("port=\(owned.nfsPort),") else { return false }
            let local = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/stat"),
                arguments: ["-f", "%d:%HT", root.path, owned.mountPath], environment: ["LC_ALL": "C"], timeout: 3, outputLimit: 1024))
            let rows = String(decoding: local.output, as: UTF8.self).split(separator: "\n")
            return local.exitCode == 0 && !local.outputTruncated && rows.count == 2 && rows[0] == rows[1] && rows[0].hasSuffix(":Directory")
        } catch {
            failedDetachProbe = owned.sessionID; detachObservation = nil
            throw error
        }
    }

    /// An earlier progress sample is only a hint; shutdown rechecks ownership and idle state.
    private func finishDetachedIfReady(_ owned: WorkerRecord, sampledStats: VFSStats, sample: ProgressSample, epoch: UUID) async {
        guard !busy, generation == epoch, record?.sessionID == owned.sessionID, !mounted else { return }
        if !sampledStats.diskCache.idle || sample.moves?.holdsWorker == true || (sample.expectsMoves && sample.moves == nil) {
            updateDetachedMessage(stats: sampledStats)
            return
        }
        await perform { [self] in
            guard record?.sessionID == owned.sessionID, generation == epoch else { return }
            generation = UUID()
            try await validateIdentity(owned)
            guard MountInspector.exactEntry(at: owned.mountPath, entries: try MountInspector.snapshot()) == nil else {
                throw DriveError.message("A Finder volume appeared while finishing eject. Worker and records were retained.")
            }
            let stats = try await authenticatedStats(owned, requireObservedBinding: owned.observedFS != nil)
            apply(stats); applyProgress(await sampleProgress(owned, stats: stats))
            let moves = try await moveStatusBeforeStop(owned, stats: stats)
            guard stats.diskCache.idle && (moves?.safeToStop ?? true) else {
                updateDetachedMessage(stats: stats)
                return
            }
            try await finishDetachedWorker(owned)
        }
    }

    private func finishDetachedWorker(_ owned: WorkerRecord) async throws {
        // Capture publications that finished during the eject drain before the
        // worker's process-local feed disappears. Metadata failure never blocks eject.
        if let catalog = catalogController, catalog.automaticEnabled {
            do {
                let cursor = try await catalog.workerCursor()
                let body = try JSONSerialization.data(withJSONObject:["after":cursor.sequence,"limit":256])
                let data = try await client(owned).call(route:"vfs/metadata-changes",body:body)
                guard connection.fingerprint == owned.destinationFingerprint else { throw CatalogFailure.superseded }
                if try await catalog.recordWorkerChanges(data,after:cursor.sequence) { try await catalog.requireReconciliation() }
            } catch { try? await catalog.requireReconciliation() }
        }
        try Task.checkCancellation()
        // Revalidate process start identity and authenticated PID immediately before signaling.
        try await validateIdentity(owned)
        guard try await client(owned).pid() == owned.process.pid,
              owned.process.matchesRunningProcess() else { throw DriveError.message("Worker identity changed. No signal was sent.") }
        guard record?.sessionID == owned.sessionID, record?.appDetachUncertain != true,
              try await localMountDirectoryVisible(owned), owned.process.matchesRunningProcess() else {
            throw DriveError.message("Finder detach could not be confirmed immediately before shutdown. The worker and recovery record were retained.")
        }
        guard kill(owned.process.pid, SIGTERM) == 0 else { throw DriveError.message("Worker could not be stopped. Recovery record retained.") }
        operationResult = "Confirming storage worker exit…"
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while owned.process.matchesRunningProcess(), ContinuousClock.now < exitDeadline {
            // Once termination has begun, finish observation even if the UI cancels.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !owned.process.matchesRunningProcess() else { throw DriveError.message("Worker has not exited. Recovery record retained; reconnect is blocked.") }
        guard try await localMountDirectoryVisible(owned) else {
            throw DriveError.message("Finder detach could not be confirmed after shutdown. Recovery record retained.")
        }
        try await offUI {
            if let pending = try self.store.loadIntent(), pending.sessionID == owned.sessionID {
                try self.store.removeIntent(expectedSessionID: owned.sessionID)
            }
            try self.store.remove(expectedSessionID: owned.sessionID)
        }
        await refreshMoveRecords()
        record = nil; worker = nil; running = false; mounted = false; recoveryRequired = false
        uploadProgress = nil; activity = []; activityAvailable = false
        mountState = .disconnected; uploads = .unknown; detail = ""
        operationResult = "Ejected and storage worker exit confirmed. Pending cache was not deleted."
    }

    var bucketVerificationBlockedReason: String? {
        if finderMoves?.holdsWorker == true || moveRecordsPending {
            return "Bucket testing is paused while a Finder move is active or awaiting recovery. Keep CloudDrive running and finish or resume the move first. Finder browsing may also wait while this legacy move completes."
        }
        if movesExpected && (!UploadFreshness.isFresh(moveSampledAt, at: Date()) || finderMoves == nil) {
            return "Waiting for current Finder move status before testing the bucket. Keep CloudDrive running."
        }
        return nil
    }
    var canVerifyBucket: Bool { mounted && !busy && !namespaceEngine.ownsDestination && bucketVerificationBlockedReason == nil }

    func verifyBucket() async {
        if let reason = bucketVerificationBlockedReason {
            operationResult = reason; lastOperationFailed = false; return
        }
        guard canVerifyBucket, let owned = record else { return }
        await perform { [self] in
            try await validateIdentity(owned)
            let stats = try await authenticatedStats(owned)
            let moves = try await moveStatusBeforeStop(owned, stats: stats)
            if moves?.holdsWorker == true {
                operationResult = bucketVerificationBlockedReason ?? "Finish the Finder move before testing the bucket."
                return
            }
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
        let moves: FinderMoveStatus?
        let expectsMoves: Bool
        let exclusiveCreate: Bool?
    }

    private func checkExclusiveCreate(_ owned: WorkerRecord) async -> Bool? {
        if let proof = dropWorkerProof, proof.session == owned.sessionID { return proof.exclusive }
        guard let version = try? await client(owned).call(route: "core/version"),
              let qualified = MountedDrop.qualifiedWorker(versionResponse: version) else { return nil }
        guard qualified else { return false }
        // Process identity, authenticated PID and destination binding were checked
        // by authenticatedStats. Match both executable copies once per worker session.
        let bundled = binary
        return try? await offUI {
            guard try Self.digest(bundled) == owned.executableSHA256 else { return false }
            return try Self.digest(URL(fileURLWithPath: owned.process.executablePath)) == owned.executableSHA256
        }
    }
    private func sampleProgress(_ owned: WorkerRecord, stats: VFSStats) async -> ProgressSample {
        let control = client(owned)
        async let exclusiveCreate = checkExclusiveCreate(owned)
        async let queueData = try? control.call(route: "vfs/queue")
        async let transferData = try? control.call(route: "core/stats")
        async let limit = try? control.uploadLimit()
        async let moveStatus = try? readFinderMoveStatus(owned)
        let queue = await queueData.flatMap { try? UploadQueue.decode($0) }
        let transfers = await transferData.flatMap { try? TransferStats.decode($0) }
        let snapshot: UploadProgressSnapshot?
        if let queue, let transfers { snapshot = UploadProgressSnapshot.make(queue: queue, stats: transfers, destination: stats.fs) }
        else { snapshot = nil }
        let moves = await moveStatus
        return await ProgressSample(queue: queue, snapshot: snapshot, uploadLimit: limit, sessionID: owned.sessionID, moves: moves, expectsMoves: stats.cacheOptions?.moveJournal?.isEmpty == false, exclusiveCreate: exclusiveCreate)
    }
    private func applyProgress(_ sample: ProgressSample) {
        dropWorkerProof = sample.exclusiveCreate.map { (sample.sessionID, $0, Date()) }
        finderMoves = sample.moves; moveSampledAt = sample.moves == nil ? nil : Date(); movesExpected = sample.expectsMoves
        if let moves = sample.moves, moves.enabled { moveRecordsPending = moves.holdsWorker; moveRecordsChecked = true }
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
    func installCatalogForTesting(_ controller: CatalogController) {
        catalogController?.stopAutomaticUpdates()
        catalogController = controller; controller.configure(connection:connection)
    }
    func relinquishForTesting() async {
        catalogController?.stopAutomaticUpdates()
        await directUploads.relinquishForTesting()
        polling?.cancel(); polling = nil; ownerLock = nil
    }
    #endif
}

/// The worker accepts paths relative to its own remote. Never pass a filesystem URL to it.
struct DriveMoveRequest: Encodable {
    struct Receipt: Decodable { let accepted: Bool; let id: String?; let reason: String? }
    let source: String
    let destination: String
    let requestID: String

    init(source item: URL, folder: URL, under root: URL, name: String? = nil) throws {
        func relative(_ url: URL) throws -> [String] {
            let base = root.standardizedFileURL.pathComponents
            let parts = url.standardizedFileURL.pathComponents
            guard root.isFileURL, url.isFileURL, parts.starts(with: base),
                  !url.pathComponents.contains("..") else {
                throw DriveError.message("Choose an item and a destination on this CloudDrive.")
            }
            return Array(parts.dropFirst(base.count))
        }
        let selected = try relative(item)
        let target = try relative(folder)
        guard let basename = selected.last, !target.starts(with: selected),
              Array(selected.dropLast()) != target else {
            throw DriveError.message("Choose a different destination outside the selected item.")
        }
        source = selected.joined(separator: "/")
        let leaf = name ?? basename
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/"), leaf.utf8.count <= 255,
              leaf.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw DriveError.message("Enter a file or folder name without slashes or control characters.")
        }
        destination = (target + [leaf]).joined(separator: "/")
        requestID = UUID().uuidString.lowercased()
    }
}
