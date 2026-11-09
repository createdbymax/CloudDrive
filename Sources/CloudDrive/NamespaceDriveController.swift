import AppKit
import Foundation
import Combine
import CryptoKit
import CloudDriveCore
import Darwin

/// The app is a client of the same owner used by Finder. It never writes the
/// namespace database or publishes upload keys behind the owner's back.
@MainActor final class NamespaceDriveController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var running = false
    @Published private(set) var mounted = false
    @Published private(set) var enabled = false
    @Published private(set) var readOnly = true
    @Published private(set) var mode: NamespaceStorageMode = .compatible
    @Published private(set) var status: SyncEngineStatus?
    @Published private(set) var statusSampledAt: Date?
    @Published private(set) var activity: [NamespaceActivityItem] = []
    @Published private(set) var activitySampledAt: Date?
    @Published private(set) var activityAvailability: [UUID: String] = [:]
    @Published private(set) var importProgress: NamespaceImportProgress?
    @Published private(set) var message = ""
    @Published private(set) var error = ""
    @Published private(set) var capabilityBlocked = false
    @Published private(set) var encrypted = false
    @Published private(set) var appliedUploadBytesPerSecond: Int64?
    @Published private(set) var speedHistory = UploadSpeedHistory()
    private let networkSampler = NetworkOutSampler()
    var uploadRate: () -> Int64 = { 0 }
    private struct EncryptionSelection: Codable { var version = 1; let binding: String; let keyID: String; var recovering: Bool? = nil }
    private var encryptionSelectionURL: URL { baseStateDirectory.appendingPathComponent("encryption-selection.json") }
    private let root: URL
    private let engineBinaryOverride: URL?
    private let fixtureRemoteDirectory: URL?
    private var connection = Connection()
    private var record: Session?
    private var process: Process?
    private var polling: Task<Void, Never>?
    private var activityPolling: Task<Void, Never>?
    private var epoch = UUID()
    private var retireWhenIdle = false
    private var selectedStorageDirectory: URL?
    private var recoveredManaged = false
    private var writesAdmitted = false
    var legacySafetyCheck: () -> Bool = { false }
    var onRevision: (Int64) -> Void = { _ in }
    private struct Session: Codable, Equatable {
        var binding: String
        var resource: URL
        var binary: URL
        var digest: String
        var identity: ProcessIdentity?
        var sessionID: UUID
        var mode: NamespaceStorageMode
        var mountID: String? = nil
        var storageDirectory: URL? = nil
        var restoreManaged: Bool? = nil
        var bootSession: String? = nil
    }
    private struct Capability: Codable { var version = 1; var binding: String; var mode: NamespaceStorageMode; var storageDirectory: URL? = nil; var recoveredManaged: Bool? = nil; var acceptsWrites: Bool? = nil }
    init(root: URL) { self.root = root; engineBinaryOverride = nil; fixtureRemoteDirectory = nil }
    #if DEBUG
    init(root: URL, engineBinary: URL, fixtureRemoteDirectory: URL) {
        self.root = root; engineBinaryOverride = engineBinary; self.fixtureRemoteDirectory = fixtureRemoteDirectory
    }
    var mountSnapshotForTesting: (() throws -> [MountEntry])?
    var beforeStatusPublishForTesting: (() async -> Void)?
    var rpcFailureForTesting: ((String) -> POSIXError?)?
    var beforeEncryptionKeySaveForTesting: (() throws -> Void)?
    func refreshForTesting() async throws { guard isFixture else { throw POSIXError(.EPERM) }; try await refresh() }
    func relinquishForTesting() {
        guard isFixture else { return }; epoch = UUID(); cancelPolling(); record = nil; process = nil; running = false
    }
    #endif
    private var isFixture: Bool {
        #if DEBUG
        return engineBinaryOverride != nil && fixtureRemoteDirectory != nil
        #else
        return false
        #endif
    }
    deinit { polling?.cancel(); activityPolling?.cancel() }
    var mountpoint: URL { root.appendingPathComponent("Instant Drive", isDirectory: true) }
    private var sessionURL: URL { root.appendingPathComponent("namespace-owner.json") }
    private var baseStateDirectory: URL { root.appendingPathComponent("Namespaces/" + connection.fingerprint) }
    private var stateDirectory: URL { selectedStorageDirectory ?? baseStateDirectory }
    private var capabilityURL: URL { baseStateDirectory.appendingPathComponent("capability.json") }
    var hasSession: Bool { record != nil || Self.itemExists(sessionURL) }
    var ownsDestination: Bool { enabled || encrypted || hasSession || capabilityBlocked }
    var canQuit: Bool { !busy && !hasSession && !mounted }
    var canMount: Bool { !busy && running && !mounted && !capabilityBlocked && importProgress?.complete == true && extensionAvailable }
    var canEnable: Bool { !busy && !capabilityBlocked && running && readOnly && importProgress?.complete == true && extensionAvailable && !mounted }
    var extensionAvailable: Bool {
        if isFixture { return true }
        if #available(macOS 26.0, *) {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/CloudDriveFS.appex/Contents/embedded.provisionprofile").isFileURL &&
                FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/CloudDriveFS.appex/Contents/embedded.provisionprofile").path)
        }
        return false
    }
    func configure(_ value: Connection) {
        guard !busy || connection.fingerprint == value.fingerprint else { return }
        guard !hasSession || connection.fingerprint == value.fingerprint || connection.endpoint.isEmpty else { return }
        configureUnchecked(value)
    }
    private func configureUnchecked(_ value: Connection) {
        if connection.fingerprint != value.fingerprint {
            epoch = UUID(); cancelPolling(); status = nil; statusSampledAt = nil; appliedUploadBytesPerSecond = nil; activity = []; activitySampledAt = nil; activityAvailability = [:]; importProgress = nil; selectedStorageDirectory = nil; recoveredManaged = false
        }
        connection = value; capabilityBlocked = false
        encrypted = Self.itemExists(encryptionSelectionURL)
        if encrypted {
            do {
                let selection = try JSONDecoder().decode(EncryptionSelection.self, from: Self.privateData(encryptionSelectionURL))
                guard selection.version == 1, selection.binding == value.fingerprint, selection.keyID.count == 64 else { throw POSIXError(.EPERM) }; mode = .managed; recoveredManaged = selection.recovering == true
            } catch { capabilityBlocked = true; self.error = "Encryption records need recovery. No unencrypted owner was started."; return }
        }
        guard Self.itemExists(capabilityURL) else { enabled = false; writesAdmitted = false; return }
        do {
            let capability = try JSONDecoder().decode(Capability.self, from: Self.privateData(capabilityURL))
            guard capability.version == 1, capability.binding == value.fingerprint else { throw POSIXError(.EPERM) }
            if let selected = capability.storageDirectory { try Self.validateStorageDirectory(selected, base: baseStateDirectory) }; selectedStorageDirectory = capability.storageDirectory
            recoveredManaged = capability.recoveredManaged == true; mode = capability.mode; enabled = true
            writesAdmitted = capability.acceptsWrites ?? true; readOnly = !writesAdmitted
        } catch {
            enabled = false; writesAdmitted = false; capabilityBlocked = true
            self.error = "Saved drive mode needs recovery. Its records were preserved; no writable owner was started."
        }
    }
    func prepare(connection: Connection, mode: NamespaceStorageMode, legacySafe: Bool) async {
        guard !busy else { return }
        await perform {
            guard legacySafe, self.legacySafetyCheck(), !self.hasSession, !self.enabled else { throw DriveError.message("Finish and recover existing moves and uploads before switching file management.") }
            if !self.isFixture { try connection.validate() }; self.configureUnchecked(connection)
            guard !self.capabilityBlocked, !self.enabled, !self.encrypted || mode == .managed else { throw POSIXError(.EPERM) }; self.mode = mode
            try await self.launch(readOnly: true, restoreManaged: self.encrypted && self.recoveredManaged)
            self.message = "Ready to preview your files. Import reads metadata and preserves the original objects."
        }
    }
    func prepareEncrypted(connection: Connection, secret: DriveEncryptionSecret, recovering: Bool, legacySafe: Bool) async {
        await perform {
            guard legacySafe, self.legacySafetyCheck(), !self.hasSession, !self.enabled else { throw POSIXError(.EBUSY) }
            if !self.isFixture { try connection.validate() }
            self.configureUnchecked(connection)
            guard !self.capabilityBlocked else { throw POSIXError(.EPERM) }
            try secret.validate()
            try await self.verifyEncryptedSelection(secret, recovering: recovering)
            guard !Self.itemExists(self.baseStateDirectory.appendingPathComponent("Namespace")) else {
                throw DriveError.message("Encryption requires a new local namespace and an empty remote prefix. Existing files were preserved.")
            }
            if Self.itemExists(self.encryptionSelectionURL) {
                let selection = try JSONDecoder().decode(EncryptionSelection.self, from: Self.privateData(self.encryptionSelectionURL))
                guard selection.binding == connection.fingerprint, selection.keyID == secret.keyID else { throw POSIXError(.EPERM) }
            }
            try Self.secureDirectory(self.root, createParents: true)
            try Self.secureDirectory(self.root.appendingPathComponent("Namespaces"))
            try Self.secureDirectory(self.baseStateDirectory)
            try Self.save(EncryptionSelection(binding: connection.fingerprint, keyID: secret.keyID, recovering: recovering), at: self.encryptionSelectionURL)
            self.encrypted = true; self.mode = .managed; self.recoveredManaged = recovering
            // Persist mode/recovery intent before Keychain mutation. If saving
            // is interrupted, importing the kit resumes this exact intent.
            #if DEBUG
            if self.isFixture { try self.beforeEncryptionKeySaveForTesting?() }
            #endif
            try await DriveEncryptionKeyStore.session(binding: connection.fingerprint).save(secret)
            try await self.launch(readOnly: true, restoreManaged: recovering)
            if recovering {
                try Self.save(Capability(binding: connection.fingerprint, mode: .managed, recoveredManaged: true, acceptsWrites: false), at: self.capabilityURL)
                self.enabled = true; self.writesAdmitted = false
            }
            self.message = recovering ? "Encrypted drive recovered into a read-only preview." : "Encrypted drive prepared. Import the empty file list, then enable changes."
        }
    }
    private func verifyEncryptedSelection(_ secret: DriveEncryptionSecret, recovering: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("clouddrive-key-check-" + UUID().uuidString)
        try Self.secureDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let remote: any StorageRemote
        if isFixture, let fixtureRemoteDirectory { remote = try FixtureStorageRemote(directory: fixtureRemoteDirectory) }
        else { remote = try S3StorageRemote(configuration: .init(endpoint: connection.endpoint, bucket: connection.bucket,
            prefix: connection.prefix, accessKey: connection.accessKey, secretKey: connection.secretKey), multipartDirectory: temporary.appendingPathComponent("Multipart")) }
        let prefix = isFixture ? "fixture" : connection.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if recovering {
            let encryptedRemote = try EncryptedStorageRemote(base: remote, masterKey: secret.key, keyID: secret.keyID, prefix: prefix,
                journalDirectory: temporary.appendingPathComponent("Encryption"))
            let key = prefix + "/.clouddrive/v1/HEAD"
            guard let head = try await encryptedRemote.head(key: key), head.size > 0, head.size <= 4096 else {
                throw DriveError.message("No encrypted drive was found at this prefix. Nothing was saved.")
            }
            let bytes = try await encryptedRemote.read(key: key, range: 0..<head.size, validator: head.validator)
            let publication = try JSONDecoder().decode(ManagedHead.self, from: bytes.data)
            guard (1...2).contains(publication.version) else { throw POSIXError(.EPROTO) }
        } else {
            guard try await remote.head(key: prefix) == nil,
                  try await remote.list(prefix: prefix + "/", cursor: nil, limit: 1).objects.isEmpty else {
                throw DriveError.message("Choose an empty R2 prefix for the encrypted drive. Existing objects were preserved.")
            }
        }
    }
    func restoreEncryptionKey(_ secret: DriveEncryptionSecret) async {
        await perform {
            guard self.encrypted else { throw POSIXError(.EPERM) }
            try secret.validate()
            let selection = try JSONDecoder().decode(EncryptionSelection.self, from: Self.privateData(self.encryptionSelectionURL))
            guard selection.version == 1, selection.binding == self.connection.fingerprint, selection.keyID == secret.keyID else {
                throw DriveError.message("This kit belongs to a different encrypted drive. The saved key and files were preserved.")
            }
            try await DriveEncryptionKeyStore.session(binding: self.connection.fingerprint).save(secret)
            self.message = "Encryption key restored. Reconnect to continue; file records were preserved."
        }
    }
    func unlockEncryption() async {
        await perform {
            guard self.encrypted, let secret = try await DriveEncryptionKeyStore.session(binding: self.connection.fingerprint).load(allowInteraction: true) else {
                throw DriveError.message("Import your recovery kit to restore the encryption key.")
            }
            let selection = try JSONDecoder().decode(EncryptionSelection.self, from: Self.privateData(self.encryptionSelectionURL))
            guard secret.keyID == selection.keyID else { throw POSIXError(.EPERM) }
            self.message = "Encryption key unlocked for this session. You can reconnect the drive."
        }
    }
    func prepareManagedRecovery(connection: Connection, legacySafe: Bool) async {
        await perform {
            guard legacySafe, self.legacySafetyCheck(), !self.hasSession, !self.enabled, !self.capabilityBlocked else { throw POSIXError(.EBUSY) }
            if !self.isFixture { try connection.validate() }; self.configureUnchecked(connection)
            guard !self.enabled, !self.capabilityBlocked else { throw POSIXError(.EPERM) }
            try Self.secureDirectory(self.root, createParents: true)
            try Self.secureDirectory(self.root.appendingPathComponent("Namespaces"))
            try Self.secureDirectory(self.baseStateDirectory)
            let recovered = self.baseStateDirectory.appendingPathComponent("Recovered")
            try Self.secureDirectory(recovered)
            let selected = recovered.appendingPathComponent(UUID().uuidString)
            try Self.secureDirectory(selected); try Self.validateStorageDirectory(selected, base: self.baseStateDirectory)
            self.selectedStorageDirectory = selected; self.recoveredManaged = true; self.mode = .managed
            try await self.launch(readOnly: true, restoreManaged: true)
            // A recovered managed layout must not silently fall back to a raw-key
            // writer after app restart. Persist selection separately from write admission.
            try Self.save(Capability(binding: self.connection.fingerprint, mode: .managed, storageDirectory: selected,
                                     recoveredManaged: true, acceptsWrites: false), at: self.capabilityURL)
            self.enabled = true; self.writesAdmitted = false
            self.message = "Recovered the published drive into a new local store. Earlier local records and original R2 objects were preserved. Review the file list before enabling changes."
        }
    }
    func recover() async {
        guard !busy else { return }
        await perform {
            guard !self.capabilityBlocked else { throw DriveError.message("Saved drive mode needs recovery. No writable owner was started; all records were retained.") }
            guard Self.itemExists(self.sessionURL) else {
                if self.enabled {
                    guard self.legacySafetyCheck() else { throw POSIXError(.EBUSY) }
                    try await self.launch(readOnly: !self.writesAdmitted)
                }
                return
            }
            var saved = try JSONDecoder().decode(Session.self, from: Self.privateData(self.sessionURL))
            guard saved.binary.isFileURL, saved.resource.isFileURL, saved.binding == self.connection.fingerprint, try WorkerRecord.digest(saved.binary) == saved.digest else { throw POSIXError(.EPERM) }
            if let selected = saved.storageDirectory { try Self.validateStorageDirectory(selected, base: self.baseStateDirectory) }
            self.selectedStorageDirectory = saved.storageDirectory; self.recoveredManaged = saved.restoreManaged == true || self.recoveredManaged
            let previousBootEnded = saved.bootSession.flatMap { previous in Self.bootSessionIdentifier().map { previous != $0 } } == true
            if saved.identity?.hasExited == true || (saved.identity == nil && previousBootEnded) {
                guard MountInspector.exactEntry(at: self.mountpoint.path, entries: try self.mountSnapshot()) == nil else { throw POSIXError(.EBUSY) }
                // State and capability remain authoritative after a stopped owner.
                try Self.removeSession(saved, at: self.sessionURL); self.record = nil; self.running = false
                guard self.legacySafetyCheck() else { throw POSIXError(.EBUSY) }
                self.mode = saved.mode
                try await self.launch(readOnly: !self.writesAdmitted, restoreManaged: !self.writesAdmitted && saved.restoreManaged == true)
                return
            }
            if saved.identity == nil, !Self.itemExists(saved.resource.appendingPathComponent(".clouddrive-owner.json")) {
                throw DriveError.message("Drive startup was interrupted before its owner could be identified. Restart this Mac, then recover file management. Saved files and launch records were retained.")
            }
            let descriptor = try NamespaceOwnerDescriptor.read(from: saved.resource.appendingPathComponent(".clouddrive-owner.json"))
            guard descriptor.binding == saved.binding, descriptor.sessionID == saved.sessionID else { throw POSIXError(.EPERM) }
            let response = try await UnixSocketRPCClient(descriptor: descriptor).call(.init(operation: "status"))
            guard let pid = response.attributes?["pid"].flatMap(Int32.init) else { throw POSIXError(.EPERM) }
            let observed = try ProcessIdentity.capture(pid: pid)
            guard observed.executablePath == (try Self.canonicalPath(saved.binary)), saved.identity == nil || saved.identity == observed else { throw POSIXError(.EPERM) }
            saved.identity = observed
            if let entry = MountInspector.exactEntry(at: self.mountpoint.path, entries: try self.mountSnapshot()) {
                try Self.validateMount(entry, resource: saved.resource, mountpoint: self.mountpoint, expectedID: saved.mountID)
                saved.mountID = entry.id; self.mounted = true
            } else { self.mounted = false }
            try Self.saveSession(saved, at: self.sessionURL, expectedID: saved.sessionID)
            self.record = saved; self.running = true; self.mode = saved.mode
            try await self.refresh()
            await self.refreshImportProgress()
        }
    }
    func importMetadata() async {
        await perform {
            let response = try await self.call(.init(operation: "import"))
            guard let data = response.data else { throw POSIXError(.EIO) }
            self.importProgress = try JSONDecoder().decode(NamespaceImportProgress.self, from: data)
            self.message = "Imported file metadata. Original files and remote paths are preserved."
        }
    }
    func enableWrites() async {
        guard canEnable else { return }
        await perform {
            guard self.legacySafetyCheck(), self.importProgress?.complete == true, !self.mounted else { throw POSIXError(.EBUSY) }
            if self.mode == .managed && !self.recoveredManaged { _ = try await self.call(.init(operation: "seedManaged")) }
            if self.mode == .compatible { _ = try await self.call(.init(operation: "qualifyStorage")) }
            // Persist storage capability before admitting any accepted new writes.
            try Self.save(Capability(binding: self.connection.fingerprint, mode: self.mode, storageDirectory: self.selectedStorageDirectory, recoveredManaged: self.recoveredManaged, acceptsWrites: true), at: self.capabilityURL)
            self.enabled = true; self.writesAdmitted = true; self.capabilityBlocked = false
            _ = try await self.call(.init(operation: "enableWrites")); self.readOnly = false
            self.message = "File management is enabled. Local changes are saved first, then synced to R2."
        }
    }
    func mount() async {
        guard canMount else { return }
        await perform {
            guard var owned = self.record, self.importProgress?.complete == true, !self.capabilityBlocked else { throw POSIXError(.ENOENT) }
            try self.validate(owned)
            guard MountInspector.exactEntry(at: self.mountpoint.path, entries: try self.mountSnapshot()) == nil else { throw POSIXError(.EBUSY) }
            try Self.prepareMountDirectory(self.mountpoint)
            var args = ["-F", "-t", "clouddrive"]
            if self.readOnly { args += ["-o", "rdonly"] }
            args += [owned.resource.path, self.mountpoint.path]
            let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/mount"), arguments: args, timeout: 20))
            guard let entry = MountInspector.exactEntry(at: self.mountpoint.path, entries: try self.mountSnapshot()) else { throw DriveError.message("macOS could not confirm the new Finder mount. Check the filesystem extension in System Settings; all records were retained.") }
            try Self.validateMount(entry, resource: owned.resource, mountpoint: self.mountpoint, expectedID: nil)
            owned.mountID = entry.id; try Self.saveSession(owned, at: self.sessionURL, expectedID: owned.sessionID); self.record = owned
            self.mounted = true
            guard result.exitCode == 0 else { throw DriveError.message("Finder mounted, but macOS did not confirm the command result. Its owned mount and recovery records were retained.") }
             self.message = self.readOnly ? "Finder preview is read-only." : "Finder is connected. Changes sync in the background."
            NSWorkspace.shared.open(self.mountpoint)
        }
    }
    func eject() async {
        guard !busy, hasSession else { return }
        await perform {
            if let entry = MountInspector.exactEntry(at: self.mountpoint.path, entries: try self.mountSnapshot()) {
                guard let owned = self.record, let mountID = owned.mountID else { throw POSIXError(.EPERM) }
                try Self.validateMount(entry, resource: owned.resource, mountpoint: self.mountpoint, expectedID: mountID)
                try self.validate(owned)
                let result = try await CommandRunner.run(CommandSpec(executable: URL(fileURLWithPath: "/sbin/umount"), arguments: [self.mountpoint.path], timeout: 15))
                guard result.exitCode == 0 else { throw DriveError.message("Close files and Finder windows on this drive, then retry eject. Nothing was forced.") }
            }
            guard MountInspector.exactEntry(at: self.mountpoint.path, entries: try self.mountSnapshot()) == nil else { throw POSIXError(.EBUSY) }
            self.mounted = false
            self.retireWhenIdle = true
            _ = try await self.call(.init(operation: "detach")); try await self.refresh()
            self.message = self.status?.pending == 0 ? "Finder ejected." : "Finder ejected. Changes continue syncing; keep CloudDrive running."
            try await self.stopIfReady()
        }
    }
    func resume() async { await perform { guard !self.capabilityBlocked else { throw POSIXError(.EPERM) }; _ = try await self.call(.init(operation: "resume")); try await self.refresh() } }
    func pause() async { await perform { _ = try await self.call(.init(operation: "pause")); try await self.refresh() } }
    func keepDownloaded(_ id: UUID) async {
        await perform { _ = try await self.call(.init(operation: "pin", nodeID: id, attributes: ["recursive": "true"])); try await self.refresh() }
    }
    func freeLocalSpace(_ id: UUID) async {
        await perform {
            _ = try await self.call(.init(operation: "unpin", nodeID: id, attributes: ["recursive": "true"]))
            _ = try await self.call(.init(operation: "freeLocalSpace", nodeID: id, attributes: ["recursive": "true"]))
            try await self.refresh()
        }
    }
    /// URL requests are only intent. The UI confirms them and this boundary
    /// binds them to the current owned mount and authenticated namespace owner.
    func setUploadRate(_ rate: Int64) async -> Bool {
        guard !busy, running else { return false }
        await perform {
            let response = try await self.call(.init(operation: "configureUploadRate", offset: max(0, rate)))
            guard response.attributes?["uploadRateBytesPerSecond"].flatMap(Int64.init) == max(0, rate) else { throw POSIXError(.EPROTO) }
            try await self.refresh()
        }
        return error.isEmpty && appliedUploadBytesPerSecond == max(0, rate)
    }
    func handleFinderAction(_ request: FinderActionRequest) async {
        guard request.action == .keepDownloaded || request.action == .freeSpace else { return }
        await perform {
            guard let owned = self.record else { throw POSIXError(.ENOTCONN) }
            @MainActor func validateSelectionSession() throws {
                guard self.enabled, self.running, self.mounted, !self.readOnly,
                      self.record?.sessionID == owned.sessionID, self.connection.fingerprint == owned.binding,
                      let entry = MountInspector.exactEntry(at: self.mountpoint.path, entries: try self.mountSnapshot()) else { throw POSIXError(.ENOTCONN) }
                try Self.validateMount(entry, resource: owned.resource, mountpoint: self.mountpoint, expectedID: owned.mountID)
                try self.validate(owned)
            }
            try validateSelectionSession()
            let selections = try request.relativeSelections(under: self.mountpoint)
            let volume = try await self.call(.init(operation: "volume"))
            guard let root = volume.volume?.rootID else { throw POSIXError(.EIO) }
            var resolved: [UUID] = [], seen: Set<UUID> = []
            // Resolve every selection before changing cache policy. One invalid
            // path cannot leave earlier selections pinned or evicted as a side effect.
            for components in selections {
                var id = root
                for component in components {
                    let reply = try await self.call(.init(operation: "lookup", parentID: id, name: component))
                    guard let node = reply.node else { throw POSIXError(.ENOENT) }
                    id = node.id
                }
                if seen.insert(id).inserted { resolved.append(id) }
            }
            for id in resolved {
                try validateSelectionSession()
                switch request.action {
                case .keepDownloaded:
                    _ = try await self.call(.init(operation: "pin", nodeID: id, attributes: ["recursive": "true"]))
                case .freeSpace:
                    _ = try await self.call(.init(operation: "unpin", nodeID: id, attributes: ["recursive": "true"]))
                    try validateSelectionSession()
                    _ = try await self.call(.init(operation: "freeLocalSpace", nodeID: id, attributes: ["recursive": "true"]))
                case .activity, .move: break
                }
            }
            try await self.refresh()
        }
    }
    func moveToTrash(_ id: UUID) async {
        await perform {
            _ = try await self.call(.init(operation: "trash", nodeID: id))
            try await self.refresh()
            self.message = "Moved to Recently Deleted. Files are retained until you restore them."
        }
    }
    func trashEntries(after cursor: String? = nil) async throws -> (entries: [NamespaceTrashEntry], next: String?) {
        let response = try await call(.init(operation: "trashList", cookie: cursor, limit: 200))
        return (try JSONDecoder().decode([NamespaceTrashEntry].self, from: response.data ?? Data()), response.nextCookie)
    }
    /// Returns accepted deletion even if a later status refresh fails. The UI must
    /// not offer the same irreversible action again merely because telemetry failed.
    func purgeTrash(_ containerID: UUID) async -> Bool {
        guard !busy, running, !readOnly else { return false }
        var accepted = false
        await perform {
            let response = try await self.call(.init(operation: "purgeTrash", nodeID: containerID))
            guard response.attributes?["removedFromRecentlyDeleted"] == "true" else { throw POSIXError(.EPROTO) }
            accepted = true
            try await self.refresh()
            self.message = "Removed from Recently Deleted. Historical cloud data may remain; this is not secure erasure."
        }
        return accepted
    }
    func restoreTrash(_ id: UUID, name: String? = nil) async {
        await perform {
            _ = try await self.call(.init(operation: "restoreTrash", nodeID: id, destinationName: name))
            try await self.refresh()
            self.message = "File restored. If its original folder is unavailable, find it at the drive root."
        }
    }
    func search(_ query: CatalogQuery) async throws -> [CatalogObject] {
        guard enabled else { return [] }
        _ = try query.terms()
        // An ejected drive can still serve its saved namespace without mounting
        // Finder. Recovery reuses the persisted owner and write-admission rules.
        if !running { await recover() }
        guard running else { throw POSIXError(.ENOTCONN) }
        let response = try await call(.init(operation: "search", name: query.text, limit: 1000))
        let results: [CatalogObject] = (response.nodes ?? []).compactMap { node in
            guard node.size >= query.minimumSize, let path = response.attributes?[node.id.uuidString],
                  query.fileExtension.isEmpty || (node.name as NSString).pathExtension.caseInsensitiveCompare(query.fileExtension) == .orderedSame else { return nil }
            return CatalogObject(key: connection.prefix + "/" + path, size: node.size, modified: node.modifiedAt, etag: node.id.uuidString, nodeID: node.id, availability: CatalogAvailability(rawValue: response.attributes?["availability:" + node.id.uuidString] ?? "") ?? .unknown, availabilityCheckedAt: Date())
        }
        return Array(results.dropFirst(query.offset).prefix(query.limit))
    }
    func enqueue(_ urls: [URL]) async {
        await perform {
            guard self.enabled, !self.readOnly else { throw POSIXError(.EROFS) }
            guard let volume = try await self.call(.init(operation: "volume")).volume else { throw POSIXError(.EIO) }
            for url in urls { try await self.enqueue(url, parent: volume.rootID, depth: 0) }
            self.message = "Files queued. Keep the original source drive connected until upload finishes."
        }
    }
    func exportFiles(toPrefix destination: String) async {
        await perform {
            guard self.running, self.mode == .managed, !self.capabilityBlocked, self.importProgress?.complete == true else { throw POSIXError(.EPERM) }
            let prefix = self.connection.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard destination.hasPrefix(prefix + "/"), destination != prefix,
                  !destination.hasPrefix(prefix + "/.clouddrive/"), !destination.hasSuffix("/"), destination.utf8.count < 900,
                  !destination.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw POSIXError(.EINVAL) }
            let response: NamespaceRPCResponse
            do { response = try await self.call(.init(operation: "export", name: destination)) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.userInfo["failureKind"] as? String == "export.finderMetadata" {
                throw DriveError.message(NamespaceExportFailure.finderMetadataMessage)
            }
            guard let data = response.data else { throw POSIXError(.EIO) }
            let progress = try JSONDecoder().decode(NamespaceExportProgress.self, from: data)
            guard progress.destinationPrefix == destination, progress.complete else { throw POSIXError(.EIO) }
            self.message = "Exported " + progress.files.formatted() + " files to the chosen R2 folder. Original objects and drive format were preserved."
        }
    }
    private func enqueue(_ url: URL, parent: UUID, depth: Int) async throws {
        guard depth < 256 else { throw POSIXError(.ELOOP) }
        let sourcePath = url.standardizedFileURL.path, privatePath = root.standardizedFileURL.path
        guard sourcePath != privatePath, !sourcePath.hasPrefix(privatePath + "/") else {
            throw DriveError.message("Choose the original files outside CloudDrive's local storage. Use Finder to copy files already inside the drive.")
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw POSIXError(.ELOOP) }
        if values.isDirectory == true {
            let response = try await call(.init(operation: "create", parentID: parent, name: url.lastPathComponent, kind: .directory))
            guard let node = response.node else { throw POSIXError(.EIO) }
            guard let children = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in false }) else { throw POSIXError(.EIO) }
            for case let child as URL in children { try await enqueue(child, parent: node.id, depth: depth + 1) }
        } else {
            let source = try await Task.detached { try ResidentSourceIdentity.capture(url: url) }.value
            _ = try await call(.init(operation: "submitUpload", parentID: parent, name: url.lastPathComponent, data: JSONEncoder().encode(source)))
        }
    }
    private static func bootSessionIdentifier() -> String? {
        var length: size_t = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 0, length <= 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return nil }
        let value = String(cString: bytes)
        return UUID(uuidString: value)?.uuidString
    }
    private func launch(readOnly: Bool, restoreManaged: Bool = false) async throws {
        guard legacySafetyCheck(), !capabilityBlocked else { throw POSIXError(.EBUSY) }
        try Self.secureDirectory(root, createParents: true)
        try Self.secureDirectory(root.appendingPathComponent("Namespaces"))
        try Self.secureDirectory(baseStateDirectory)
        if let selectedStorageDirectory { try Self.validateStorageDirectory(selectedStorageDirectory, base: baseStateDirectory) }
        try Self.secureDirectory(stateDirectory)
        let bundled = engineBinaryOverride ?? Bundle.main.resourceURL!.appendingPathComponent("CloudDriveEngine")
        let binary = try await Task.detached(priority: .utility) { try Self.stage(bundled, root: self.root) }.value
        guard legacySafetyCheck(), !capabilityBlocked else { throw POSIXError(.EBUSY) }
        let digest = try WorkerRecord.digest(binary)
        let sessionID = UUID(), resource = try NamespaceResourceLocation.resource(sessionID: sessionID, fixture: isFixture)
        var session = Session(binding: connection.fingerprint, resource: resource, binary: binary, digest: digest, identity: nil, sessionID: sessionID, mode: mode, storageDirectory: selectedStorageDirectory, restoreManaged: restoreManaged, bootSession: Self.bootSessionIdentifier())
        let encryptionSecret: DriveEncryptionSecret?
        if Self.itemExists(encryptionSelectionURL) {
            let selection = try JSONDecoder().decode(EncryptionSelection.self, from: Self.privateData(encryptionSelectionURL))
            guard mode == .managed, selection.binding == connection.fingerprint,
                  let secret = try await DriveEncryptionKeyStore.session(binding: connection.fingerprint).load(),
                  secret.keyID == selection.keyID else { throw DriveError.message("Unlock the encrypted drive key before reconnecting.") }
            encryptionSecret = secret
        } else { encryptionSecret = nil }
        let config = NamespaceEngineConfiguration(directory: stateDirectory, binding: connection.fingerprint, mode: mode,
            storage: isFixture ? nil : .init(endpoint: connection.endpoint, bucket: connection.bucket, prefix: connection.prefix, accessKey: connection.accessKey, secretKey: connection.secretKey),
            fixtureDirectory: isFixture ? fixtureRemoteDirectory : nil, resourceDirectory: resource, sessionID: sessionID, readOnly: readOnly, restoreManaged: restoreManaged, encryptionKeyBase64: encryptionSecret?.key.base64EncodedString(), encryptionKeyID: encryptionSecret?.keyID, uploadRateBytesPerSecond: max(0, uploadRate()))
        // Durable launch intent exists before a process can become an independent owner.
        try Self.saveSession(session, at: sessionURL, expectedID: nil); record = session
        let p = Process(), input = Pipe(), output = Pipe()
        p.executableURL = binary; p.arguments = ["--serve"]; p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        #if DEBUG
        var fixtureLog: FileHandle?
        if isFixture {
            let url = root.appendingPathComponent("fixture-engine.log")
            if !Self.itemExists(url) { FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
            fixtureLog = try FileHandle(forWritingTo: url); p.standardError = fixtureLog
        }
        defer { try? fixtureLog?.close() }
        #endif
        do { try p.run() }
        catch { try Self.retireLaunch(session, at: sessionURL); record = nil; throw error }
        process = p; session.identity = try ProcessIdentity.capture(pid: p.processIdentifier)
        try Self.saveSession(session, at: sessionURL, expectedID: session.sessionID); record = session
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(config)); try input.fileHandleForWriting.close()
        let end = ContinuousClock.now.advanced(by: .seconds(120))
        var lastStartupError: Error?
        while ContinuousClock.now < end {
            guard p.isRunning else { throw DriveError.message("The file owner stopped during startup. Records were preserved for recovery.") }
            do { try await refresh(); self.readOnly = readOnly; await refreshImportProgress(); return }
            catch { lastStartupError = error; try await Task.sleep(for: .milliseconds(150)) }
        }
        NSLog("CloudDrive startup status check never succeeded; last error: %@", String(describing: lastStartupError))
        throw DriveError.message("The file owner could not be authenticated. Recovery records were retained.")
    }
    private func call(_ request: NamespaceRPCRequest) async throws -> NamespaceRPCResponse {
        guard let record else { throw POSIXError(.ENOTCONN) }
        let expectedEpoch = epoch, binding = connection.fingerprint
        try validate(record)
        #if DEBUG
        if isFixture, let failure = rpcFailureForTesting?(request.operation) { throw failure }
        #endif
        let descriptor = try NamespaceOwnerDescriptor.read(from: record.resource.appendingPathComponent(".clouddrive-owner.json"))
        guard descriptor.binding == record.binding, descriptor.sessionID == record.sessionID else { throw POSIXError(.EPERM) }
        let response: NamespaceRPCResponse
        do { response = try await UnixSocketRPCClient(descriptor: descriptor).call(request) }
        catch {
            let failure = error as NSError
            guard failure.domain == NSPOSIXErrorDomain,
                  [Int(ECONNRESET), Int(ECONNREFUSED), Int(EPIPE), Int(ETIMEDOUT)].contains(failure.code),
                  epoch == expectedEpoch, self.record?.sessionID == record.sessionID, connection.fingerprint == binding else { throw error }
            // The same UUID reaches the owner's durable replay boundary. Never
            // create a second operation merely because its reply was interrupted.
            try await Task.sleep(for: .milliseconds(50)); try validate(record)
            response = try await UnixSocketRPCClient(descriptor: descriptor).call(request)
        }
        guard epoch == expectedEpoch, self.record?.sessionID == record.sessionID, connection.fingerprint == binding else { throw CancellationError() }
        guard response.attributes?["pid"].flatMap(Int32.init) == record.identity?.pid,
              record.identity?.matchesRunningProcess() == true else { throw POSIXError(.EPERM) }
        return response
    }
    private func validate(_ session: Session) throws {
        guard session.binding == connection.fingerprint, let identity = session.identity,
              identity.executablePath == (try Self.canonicalPath(session.binary)), identity.matchesRunningProcess(),
              try WorkerRecord.digest(session.binary) == session.digest else { throw POSIXError(.EPERM) }
    }
    private func refresh() async throws {
        guard let owned = record else { throw POSIXError(.ENOTCONN) }
        let expectedEpoch = epoch, binding = connection.fingerprint
        let response = try await call(.init(operation: "status"))
        let sampledAt = Date()
        guard let data = response.data else { throw POSIXError(.EIO) }
        let updated = try JSONDecoder().decode(SyncEngineStatus.self, from: data)
        #if DEBUG
        if isFixture, let hook = beforeStatusPublishForTesting { await hook() }
        #endif
        guard epoch == expectedEpoch, record?.sessionID == owned.sessionID, connection.fingerprint == binding, !Task.isCancelled else { throw CancellationError() }
        guard updated.pending >= 0, updated.attention >= 0, updated.localRevision >= 0, updated.publishedRevision >= 0,
              updated.publishedRevision <= updated.localRevision, updated.dirtyBytes >= 0, updated.cleanCacheBytes >= 0, updated.pinnedBytes >= 0 else { throw POSIXError(.EIO) }
        if let entry = MountInspector.exactEntry(at: mountpoint.path, entries: try mountSnapshot()) {
            try Self.validateMount(entry, resource: owned.resource, mountpoint: mountpoint, expectedID: owned.mountID)
            mounted = true
        } else if mounted || owned.mountID != nil {
            // Finder can eject independently of the dashboard. Confirm absence
            // from the native mount table before retiring this exact owner.
            var detached = owned; detached.mountID = nil
            try Self.saveSession(detached, at: sessionURL, expectedID: owned.sessionID)
            record = detached; mounted = false; retireWhenIdle = true
            _ = try await call(.init(operation: "detach"))
            guard epoch == expectedEpoch, record?.sessionID == owned.sessionID else { throw CancellationError() }
        }
        let previousRevision = status?.localRevision
        status = updated; statusSampledAt = sampledAt
        speedHistory.record(bytesPerSecond: updated.uploadBytesPerSecond, pending: updated.pending, networkOut: networkSampler.sample(now: sampledAt), at: sampledAt)
        running = true
        appliedUploadBytesPerSecond = response.attributes?["uploadRateBytesPerSecond"].flatMap(Int64.init)
        readOnly = response.attributes?["readOnly"] != "false"
        if previousRevision != updated.localRevision { onRevision(updated.localRevision) }
    }
    private func refreshImportProgress() async {
        let current = epoch
        guard let reply = try? await call(.init(operation: "importProgress")), let data = reply.data,
              let progress = try? JSONDecoder().decode(NamespaceImportProgress.self, from: data),
              epoch == current, !Task.isCancelled else { return }
        importProgress = progress
    }
    private func refreshActivity() async {
        let current = epoch
        do {
            let reply = try await call(.init(operation: "activity", limit: 200))
            guard let data = reply.data else { throw POSIXError(.EIO) }
            let rows = try JSONDecoder().decode([NamespaceActivityItem].self, from: data)
            guard epoch == current, !Task.isCancelled else { return }
            activity = rows
            activityAvailability = Dictionary(uniqueKeysWithValues: Set(rows.map(\.nodeID)).map { id in
                (id, reply.attributes?["availability:" + id.uuidString] ?? "unknown")
            })
            activitySampledAt = Date()
        } catch {
            guard epoch == current, !Task.isCancelled else { return }
            activitySampledAt = nil
        }
    }
    private func stopIfReady() async throws {
        guard !mounted, let owned = record, status?.pending == 0 else { return }
        let prepared: NamespaceRPCResponse
        do { prepared = try await call(.init(operation: "prepareStop")) }
        catch {
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain && failure.code == Int(EBUSY) { return }
            throw error
        }
        guard prepared.attributes?["safeToStop"] == "true", MountInspector.exactEntry(at: mountpoint.path, entries: try self.mountSnapshot()) == nil else { throw POSIXError(.EBUSY) }
        try validate(owned)
        guard let identity = owned.identity, kill(identity.pid, SIGTERM) == 0 else { throw POSIXError(.EPERM) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !identity.hasExited, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard identity.hasExited else { throw POSIXError(.EBUSY) }
        try Self.removeSession(owned, at: sessionURL); epoch = UUID(); record = nil; process = nil; running = false; status = nil; statusSampledAt = nil; appliedUploadBytesPerSecond = nil; activity = []; activitySampledAt = nil; activityAvailability = [:]; cancelPolling()
    }
    private func cancelPolling() {
        polling?.cancel(); polling = nil
        activityPolling?.cancel(); activityPolling = nil
    }
    private func beginPolling() {
        cancelPolling(); let current = epoch, sessionID = record?.sessionID
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.epoch == current, self.record?.sessionID == sessionID else { return }
                if self.busy { continue }
                do {
                    try await self.refresh()
                    guard self.epoch == current, self.record?.sessionID == sessionID else { return }
                    if self.retireWhenIdle, !self.mounted, self.status?.pending == 0 {
                        await self.perform { try await self.refresh(); try await self.stopIfReady() }
                    }
                } catch {
                    guard self.epoch == current, self.record?.sessionID == sessionID, !self.busy, !Task.isCancelled else { return }
                    self.status = nil; self.statusSampledAt = nil; self.appliedUploadBytesPerSecond = nil
                    self.speedHistory.record(bytesPerSecond: nil, pending: 0, networkOut: self.networkSampler.sample())
                }
            }
        }
        // Journal listings and cache checks can take longer than status RPCs on large queues.
        activityPolling = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.epoch == current, self.record?.sessionID == sessionID {
                    if !self.busy {
                        await self.refreshActivity()
                        if self.epoch == current, !Task.isCancelled, self.importProgress?.complete != true {
                            await self.refreshImportProgress()
                        }
                    }
                } else { return }
                // The journal listing holds the engine's store while it runs. A deep
                // backlog needs it far less often than a small queue does.
                let interval: Int = (self?.status?.pending ?? 0) > 5_000 ? 20 : 5
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }
    private func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; epoch = UUID(); error = ""
        defer { busy = false; if record != nil && running { beginPolling() } }
        do { try await work() }
        catch {
            self.error = (error as? DriveError)?.localizedDescription ?? "The operation could not be confirmed. Saved files and recovery records were preserved."
            let code = error as NSError
            // Keep the user-facing text stable, but never hide the cause: it goes to the unified log and a short detail line.
            NSLog("CloudDrive file management failure: %@ %ld %@", code.domain, code.code, String(describing: error))
            if !(error is DriveError) { self.error += " (" + code.domain + ":" + String(code.code) + ")" }
        }
    }
    func dropMount() throws -> MountEntry {
        guard enabled, mounted, running, !busy, !readOnly, let record,
              record.binding == connection.fingerprint, let mountID = record.mountID,
              let entry = MountInspector.exactEntry(at: mountpoint.path, entries: try mountSnapshot())
        else { throw POSIXError(.ENOTCONN) }
        try Self.validateMount(entry, resource: record.resource, mountpoint: mountpoint, expectedID: mountID)
        return entry
    }
    private func mountSnapshot() throws -> [MountEntry] {
        #if DEBUG
        if isFixture, let sample = mountSnapshotForTesting { return try sample() }
        #endif
        return try MountInspector.snapshot()
    }
    static func validateMount(_ entry: MountEntry, resource: URL, mountpoint: URL, expectedID: String?) throws {
        guard entry.path == mountpoint.path, ["clouddrive", "fskit"].contains(entry.type.lowercased()), !entry.id.isEmpty else { throw POSIXError(.EPERM) }
        let path: String
        if entry.source.hasPrefix("file:") {
            guard let url = URL(string: entry.source), url.isFileURL, url.host == nil || url.host == "localhost", url.query == nil, url.fragment == nil else { throw POSIXError(.EPERM) }
            path = url.standardizedFileURL.path
        } else {
            guard entry.source.hasPrefix("/"), !entry.source.utf8.contains(0) else { throw POSIXError(.EPERM) }
            path = URL(fileURLWithPath: entry.source, isDirectory: true).standardizedFileURL.path
        }
        let lexical = resource.standardizedFileURL.path, canonical = (try? Self.canonicalPath(resource)) ?? lexical
        guard path == lexical || path == canonical, expectedID == nil || entry.id == expectedID else { throw POSIXError(.EPERM) }
    }
    private static func privateData(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw POSIXError(.EPERM) }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw POSIXError(.ENOENT) }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= 65_536 else { throw POSIXError(.EPERM) }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    private static func save<T: Encodable>(_ value: T, at url: URL, replace: Bool = true) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".save-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd); unlink(temp.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: JSONEncoder().encode(value)); try handle.synchronize()
        let renamed = replace ? rename(temp.path, url.path) : renamex_np(temp.path, url.path, UInt32(RENAME_EXCL))
        guard renamed == 0 else { throw POSIXError(.EIO) }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard parent >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }
    private static func retireLaunch(_ expected: Session, at url: URL) throws {
        guard expected.identity == nil else { throw POSIXError(.EPERM) }
        try removeSession(expected, at: url)
    }
    private static func saveSession(_ value: Session, at url: URL, expectedID: UUID?) throws {
        if let expectedID {
            let current = try JSONDecoder().decode(Session.self, from: privateData(url))
            guard current.sessionID == expectedID, current.binding == value.binding, current.digest == value.digest, current.resource == value.resource, current.mode == value.mode, current.storageDirectory == value.storageDirectory, current.restoreManaged == value.restoreManaged, current.identity == nil || current.identity == value.identity else { throw POSIXError(.EPERM) }
            try save(value, at: url)
        } else {
            guard !itemExists(url) else { throw POSIXError(.EEXIST) }
            try save(value, at: url, replace: false)
        }
    }
    private static func removeSession(_ expected: Session, at url: URL) throws {
        let current = try JSONDecoder().decode(Session.self, from: privateData(url))
        guard current == expected else { throw POSIXError(.EPERM) }
        guard unlink(url.path) == 0 else { throw POSIXError(.EIO) }; try syncParent(url)
    }
    nonisolated private static func syncParent(_ url: URL) throws {
        let fd = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
    nonisolated private static func canonicalPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }; return String(cString: resolved)
    }
    nonisolated private static func itemExists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    /// A normal FSKit eject leaves the empty mount directory behind. Never
    /// mount over another user's directory, a link, or unmounted local files.
    nonisolated static func prepareMountDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
        guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else { throw POSIXError(.ENOTEMPTY) }
    }
    nonisolated private static func secureDirectory(_ url: URL, createParents: Bool = false) throws {
        if !itemExists(url) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createParents, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), chmod(url.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    }
    nonisolated private static func validateStorageDirectory(_ selected: URL, base: URL) throws {
        guard selected.isFileURL, base.isFileURL, selected.host == nil || selected.host == "localhost" else { throw POSIXError(.EPERM) }
        let prefix = base.standardizedFileURL.path, path = selected.standardizedFileURL.path
        guard path == prefix || path.hasPrefix(prefix + "/") else { throw POSIXError(.EPERM) }
        let relative = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        var current = base
        for component in [String?](arrayLiteral: nil) + relative.map(Optional.some) {
            if let component { current.appendPathComponent(component) }
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
        }
        let realBase = try canonicalPath(base), realSelected = try canonicalPath(selected)
        guard realSelected == realBase || realSelected.hasPrefix(realBase + "/") else { throw POSIXError(.EPERM) }
    }
    nonisolated private static func stage(_ bundled: URL, root: URL) throws -> URL {
        var source = stat()
        guard lstat(bundled.path, &source) == 0, source.st_mode & S_IFMT == S_IFREG, source.st_nlink == 1 else { throw POSIXError(.EPERM) }
        let digest = try WorkerRecord.digest(bundled)
        let engines = root.appendingPathComponent("Engines"); try secureDirectory(engines)
        let directory = engines.appendingPathComponent(digest); try secureDirectory(directory)
        let target = directory.appendingPathComponent("CloudDriveEngine")
        if !itemExists(target) {
            let temporary = directory.appendingPathComponent(".engine-" + UUID().uuidString)
            defer { unlink(temporary.path) }
            try FileManager.default.copyItem(at: bundled, to: temporary)
            guard chmod(temporary.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
            let persisted = try FileHandle(forWritingTo: temporary); try persisted.synchronize(); try persisted.close()
            guard chmod(temporary.path, 0o500) == 0 else { throw POSIXError(.EPERM) }
            guard try WorkerRecord.digest(temporary) == digest else { throw POSIXError(.EPERM) }
            // The digest directory is private; refuse a concurrently created destination.
            guard renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(.EEXIST) }
            try syncParent(target)
        }
        var actual = stat()
        guard lstat(target.path, &actual) == 0, actual.st_mode & S_IFMT == S_IFREG, actual.st_uid == getuid(), actual.st_nlink == 1,
              actual.st_mode & 0o022 == 0, try WorkerRecord.digest(target) == digest else { throw POSIXError(.EPERM) }
        return URL(fileURLWithPath: try canonicalPath(target))
    }
}
