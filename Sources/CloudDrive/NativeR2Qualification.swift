import Foundation
import CryptoKit
import Darwin
import CloudDriveCore

#if DEBUG
enum NativeRunCase: String {
    case standard = "--qualify-native-r2", project = "--qualify-native-r2-project", group = "--qualify-native-r2-group", bounded = "--qualify-native-r2-bounded"
}

struct NativeR2QualificationReport: Codable {
    var schema = 1
    var state = "running"
    var stage = "preflight"
    var passed: [String] = []
    var diagnostic: String?
    var ownerPID: Int32?
    var syntheticMountPath: String?
    var syntheticResourcePath: String?
    var ownerRetained = false
    var mountMayRemain = false
    var sha256: String?
    var projectFilesVerified: Int?
    var scope = "Isolated native FSKit POSIX I/O and live R2 managed publication; remote synthetic objects retained. Not Finder UI or a general release qualification."
}

/// Publication progress extends the idle deadline, up to a fixed overall limit.
struct QualificationPublicationWindow {
    let absoluteEnd: ContinuousClock.Instant
    private var idleEnd: ContinuousClock.Instant
    private var lowestPending = Int.max
    private var highestPublished = Int64.min
    var deadline: ContinuousClock.Instant { min(absoluteEnd, idleEnd) }

    private let idleLimit: Duration

    init(start: ContinuousClock.Instant, extended: Bool = false) {
        idleLimit = .seconds(extended ? 180 : 45)
        absoluteEnd = start.advanced(by: .seconds(extended ? 1200 : 150))
        idleEnd = start.advanced(by: idleLimit)
    }

    mutating func observe(pending: Int, published: Int64, at now: ContinuousClock.Instant) {
        if now < deadline && (pending < lowestPending || published > highestPublished) {
            idleEnd = now.advanced(by: idleLimit)
        }
        lowestPending = min(lowestPending, pending)
        highestPublished = max(highestPublished, published)
    }
}

/// No user-drive session, locks, mountpoint, recovery records or remote keys are reused.
@MainActor final class NativeR2Qualification {
    static let byteCount = 2 * 1024 * 1024
    static func payload() -> Data { Data((0..<byteCount).map { UInt8(($0 / 4096 + $0 % 251) % 251) }) }
    static func prefix(parent: String, id: UUID) -> String {
        parent.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/clouddrive-native-qualification-" + id.uuidString.lowercased()
    }
    static func owned(_ entry: MountEntry, mount: URL, resource: URL) -> Bool {
        var source = entry.source
        if source.hasPrefix("file:") {
            guard let url = URL(string: source), url.isFileURL, [nil, "", "localhost"].contains(url.host), url.query == nil, url.fragment == nil else { return false }
            source = url.path
        }
        return entry.path == mount.path && ["clouddrive", "fskit"].contains(entry.type.lowercased()) && !entry.id.isEmpty && source == resource.path
    }
    private static func directory(_ url: URL, create: Bool = true) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard create, errno == ENOENT else { throw POSIXError(.EPERM) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0, url.resolvingSymlinksInPath().path == url.path else { throw POSIXError(.EPERM) }
    }
    private static func save(_ report: NativeR2QualificationReport, _ path: URL) throws {
        let bytes = try JSONEncoder().encode(report)
        try bytes.write(to: path, options: .atomic)
        guard chmod(path.path, 0o600) == 0 else { throw POSIXError(.EPERM) }
        let handle = try FileHandle(forWritingTo: path); try handle.synchronize(); try handle.close()
    }
    /// Only subprocesses created here can be signalled; the namespace owner is
    /// managed separately and is never terminated while any mount may remain.
    private static func child(_ executable: URL, args: [String], input: Data? = nil, seconds: Int) async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : pipe
        try process.run()
        if let input { try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close() }
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while process.isRunning && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(100)) }
        guard !process.isRunning else { process.terminate(); throw POSIXError(.ETIMEDOUT) }
        guard process.terminationStatus == 0 else {
            if args == ["--qualify-native-r2-exercise"], let code = POSIXErrorCode(rawValue: process.terminationStatus) { throw POSIXError(code) }
            throw POSIXError(.EIO)
        }
    }
    static func run(connection: Connection, root: URL, scenario: NativeRunCase = .standard) async -> (String, URL?) {
        var report = NativeR2QualificationReport(), reportURL: URL?
        let owner = Process(); var client: UnixSocketRPCClient?
        var mountedIdentity: MountEntry?
        do {
            try connection.validate()
            let id = UUID(), session = UUID()
            let base = root.appendingPathComponent("Qualifications"), work = base.appendingPathComponent("native-" + id.uuidString)
            try directory(root, create: false); try directory(base); try directory(work)
            let mount = work.appendingPathComponent("Mount")
            let state = scenario == .bounded ? try boundedState(work: work) : work.appendingPathComponent("State")
            try directory(state); try directory(mount)
            if scenario != .standard {
                report.scope = "Generated Finder fixture in an isolated managed R2 prefix."
            }
            let resource = try NamespaceResourceLocation.resource(sessionID: session)
            guard !FileManager.default.fileExists(atPath: resource.path),
                  MountInspector.exactEntry(at: mount.path, entries: try MountInspector.snapshot()) == nil else { throw POSIXError(.EEXIST) }
            report.syntheticMountPath = mount.path; report.syntheticResourcePath = resource.path
            reportURL = work.appendingPathComponent("report.json")
            @MainActor func checkpoint(_ stage: String) throws { report.stage = stage; try save(report, reportURL!) }
            try checkpoint("remote-preflight")
            let scope = scenario == .standard ? prefix(parent: connection.prefix, id: id) : "clouddrive-qualification-" + id.uuidString.lowercased()
            guard connection.prefix.split(separator: "/").first.map(String.init) != scope else { throw StorageFailure.conflict }
            let storage = R2StorageConfiguration(endpoint: connection.endpoint, bucket: connection.bucket,
                prefix: scope, accessKey: connection.accessKey, secretKey: connection.secretKey)
            let remote = try S3StorageRemote(configuration: storage, multipartDirectory: work.appendingPathComponent("Readback"))
            defer { remote.close() }
            let existing = try await remote.list(prefix: storage.prefix + "/", cursor: nil, limit: 1)
            guard existing.objects.isEmpty, existing.nextCursor == nil else { throw StorageFailure.conflict }
            let config = NamespaceEngineConfiguration(directory: state, binding: "native-qualification-" + id.uuidString,
                mode: .managed, storage: storage, resourceDirectory: resource, sessionID: session, readOnly: true)
            if scenario == .group {
                try checkpoint("seed-generated-tree")
                try await seedGroup(work: work, config: config, remote: remote, scope: storage.prefix)
            }
            let input = Pipe()
            owner.executableURL = Bundle.main.resourceURL!.appendingPathComponent("CloudDriveEngine")
            owner.arguments = ["--serve"]; owner.standardInput = input
            owner.standardOutput = FileHandle.nullDevice; owner.standardError = FileHandle.nullDevice
            try checkpoint("owner-start")
            try owner.run(); report.ownerPID = owner.processIdentifier; report.ownerRetained = true
            try checkpoint("owner-authentication")
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(config)); try input.fileHandleForWriting.close()
            let readyEnd = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < readyEnd {
                guard owner.isRunning else { throw POSIXError(.ECHILD) }
                if let descriptor = try? NamespaceOwnerDescriptor.read(from: resource.appendingPathComponent(".clouddrive-owner.json")) {
                    guard descriptor.binding == config.binding, descriptor.sessionID == session,
                          descriptor.socketPath == resource.appendingPathComponent("owner.sock").path else { throw POSIXError(.EPERM) }
                    client = UnixSocketRPCClient(descriptor: descriptor); break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let client else { throw POSIXError(.ETIMEDOUT) }
            // Descriptor publication precedes listen(). Retry only the harmless
            // volume read on startup races, never a mutating request.
            while true {
                do {
                    let reply = try await client.call(.init(operation: "volume"))
                    guard reply.volume?.binding == config.binding else { throw POSIXError(.EPERM) }
                    break
                } catch {
                    let failure = error as NSError
                    guard failure.domain == NSPOSIXErrorDomain,
                          [Int(ECONNREFUSED), Int(ENOENT)].contains(failure.code),
                          owner.isRunning, ContinuousClock.now < readyEnd else { throw error }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try checkpoint("managed-seed")
            _ = try await client.call(.init(operation: "seedManaged"))
            try checkpoint("owner-enable-writes")
            _ = try await client.call(.init(operation: "enableWrites"))
            report.passed.append("isolated-managed-owner-ready")
            // Persist conservative mount state before a mount helper can act.
            report.mountMayRemain = true; try checkpoint("native-mount")
            try await child(URL(fileURLWithPath: "/sbin/mount"), args: ["-F", "-t", "clouddrive", resource.path, mount.path], seconds: 25)
            guard let entry = MountInspector.exactEntry(at: mount.path, entries: try MountInspector.snapshot()), owned(entry, mount: mount, resource: resource) else { throw POSIXError(.EPERM) }
            mountedIdentity = entry; report.passed.append("native-mount-identity")
            switch scenario {
            case .project, .group:
                try checkpoint("finder-project-copy")
                try await projectExercise(work: work, mount: mount, seeded: scenario == .group)
                report.passed.append("finder-project-copy")
            case .bounded:
                try checkpoint("finder-bounded-copy")
                try await boundedExercise(work: work, mount: mount)
                report.passed.append("finder-bounded-copy")
            case .standard:
                try checkpoint("posix-write-fsync-read-rename")
                let exercise = try JSONEncoder().encode(Exercise(mount: mount, resource: resource, identity: entry.id))
                try await child(Bundle.main.executableURL!, args: ["--qualify-native-r2-exercise"], input: exercise, seconds: 40)
                report.passed.append("posix-2MiB-write-fsync-read-rename")
                report.passed.append("immediate-pending-file-replace-retains-old-reader")
            }
            try checkpoint("managed-publication")
            var publicationWindow = QualificationPublicationWindow(start: .now, extended: scenario != .standard)
            while true {
                let end = publicationWindow.deadline
                guard ContinuousClock.now < end else { throw POSIXError(.ETIMEDOUT) }
                let status = try await withThrowingTaskGroup(of: SyncEngineStatus.self) { group in
                    group.addTask {
                        _ = try await client.call(.init(operation: "sync"))
                        let reply = try await client.call(.init(operation: "status"))
                        guard let data = reply.data else { throw StorageFailure.integrity }
                        return try JSONDecoder().decode(SyncEngineStatus.self, from: data)
                    }
                    group.addTask {
                        try await Task.sleep(until: end, clock: .continuous)
                        throw POSIXError(.ETIMEDOUT)
                    }
                    defer { group.cancelAll() }
                    guard let status = try await group.next() else { throw CancellationError() }
                    return status
                }
                guard status.attention == 0 else { throw StorageFailure.integrity }
                if status.pending == 0 && status.localRevision == status.publishedRevision { break }
                publicationWindow.observe(pending: status.pending, published: status.publishedRevision, at: .now)
                try await Task.sleep(for: .milliseconds(300))
            }
            report.passed.append("managed-revision-published-and-drained")
            try checkpoint("independent-r2-readback")
            switch scenario {
            case .standard:
                report.sha256 = try await publishedHash(client: client, remote: remote, scope: storage.prefix)
            case .project, .group:
                report.projectFilesVerified = try await projectVerify(work: work, client: client, remote: remote, scope: storage.prefix, seeded: scenario == .group)
            case .bounded:
                report.sha256 = try await boundedVerify(work: work, client: client, remote: remote, scope: storage.prefix)
            }
            report.passed.append("independent-r2-published-content-sha256")
            try checkpoint("normal-unmount")
            guard let current = MountInspector.exactEntry(at: mount.path, entries: try MountInspector.snapshot()),
                  current == mountedIdentity, owned(current, mount: mount, resource: resource) else { throw POSIXError(.EPERM) }
            try await child(URL(fileURLWithPath: "/sbin/umount"), args: [mount.path], seconds: 15)
            guard MountInspector.exactEntry(at: mount.path, entries: try MountInspector.snapshot()) == nil else { throw POSIXError(.EBUSY) }
            report.mountMayRemain = false; report.passed.append("normal-unmount")
            try checkpoint("safe-owner-stop")
            _ = try await client.call(.init(operation: "detach"))
            guard try await client.call(.init(operation: "prepareStop")).attributes?["safeToStop"] == "true",
                  MountInspector.exactEntry(at: mount.path, entries: try MountInspector.snapshot()) == nil else { throw POSIXError(.EBUSY) }
            if owner.isRunning { owner.terminate() }
            let stopEnd = ContinuousClock.now.advanced(by: .seconds(5))
            while owner.isRunning && ContinuousClock.now < stopEnd { try await Task.sleep(for: .milliseconds(100)) }
            guard !owner.isRunning else { throw POSIXError(.EBUSY) }
            report.ownerRetained = false; report.passed.append("safe-owner-stop")
            report.state = "passed"; try checkpoint("complete-remote-fixture-retained")
        } catch {
            report.state = "failed"; report.diagnostic = diagnostic(error)
            // Deliberately retain mount/owner/state after any failure. Never force
            // unmount or terminate an owner when native requests may still exist.
            report.ownerRetained = owner.isRunning
            if let reportURL { try? save(report, reportURL) }
        }
        return (report.state, reportURL)
    }
    static func diagnostic(_ error: Error) -> String {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return "posix-errno-" + String(failure.code) }
        return R2QualificationScenario.diagnostic(error)
    }
    private static func publishedHash(client: UnixSocketRPCClient, remote: S3StorageRemote, scope: String) async throws -> String {
        guard let volume = try await client.call(.init(operation: "volume")).volume,
              let node = try await client.call(.init(operation: "lookup", parentID: volume.rootID, name: "replaced.bin")).node,
              let locator = node.backing, locator.key.hasPrefix(scope + "/"),
              let validator = locator.validator, !validator.isEmpty, locator.size == byteCount else { throw StorageFailure.integrity }
        let bytes = try await remote.read(key: locator.key, range: 0..<Int64(byteCount), validator: validator)
        let digest = SHA256.hash(data: payload())
        guard bytes.offset == 0, bytes.totalSize == byteCount, bytes.validator == validator,
              bytes.data.count == byteCount, SHA256.hash(data: bytes.data) == digest else { throw StorageFailure.integrity }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    /// Quiesce a retained synthetic owner only after its exact mount was normally
    /// unmounted. The operator independently checks process identity before SIGTERM.
    private static func retainedOwner(runID: UUID, root: URL) async throws -> (UnixSocketRPCClient, URL, NativeR2QualificationReport) {
        let work = root.appendingPathComponent("Qualifications").appendingPathComponent("native-" + runID.uuidString)
        try directory(work, create: false)
        let report = try JSONDecoder().decode(NativeR2QualificationReport.self, from: Data(contentsOf: work.appendingPathComponent("report.json")))
        let mount = work.appendingPathComponent("Mount")
        guard report.state == "failed", report.syntheticMountPath == mount.path,
              let path = report.syntheticResourcePath else { throw POSIXError(.EPERM) }
        let resource = URL(fileURLWithPath: path)
        guard resource.deletingLastPathComponent().path == (try NamespaceResourceLocation.sharedBase()).path,
              MountInspector.exactEntry(at: mount.path, entries: try MountInspector.snapshot()) == nil else { throw POSIXError(.EBUSY) }
        let descriptor = try NamespaceOwnerDescriptor.read(from: resource.appendingPathComponent(".clouddrive-owner.json"))
        guard descriptor.binding == "native-qualification-" + runID.uuidString,
              (try NamespaceResourceLocation.resource(sessionID: descriptor.sessionID)).path == resource.path,
              descriptor.socketPath == resource.appendingPathComponent("owner.sock").path else { throw POSIXError(.EPERM) }
        let client = UnixSocketRPCClient(descriptor: descriptor)
        let volume = try await client.call(.init(operation: "volume"))
        guard volume.volume?.binding == descriptor.binding else { throw POSIXError(.EPERM) }
        return (client, work, report)
    }
    static func quiesce(runID: UUID, root: URL) async throws {
        let (client, _, _) = try await retainedOwner(runID: runID, root: root)
        _ = try await client.call(.init(operation: "detach"))
        guard try await client.call(.init(operation: "prepareStop")).attributes?["safeToStop"] == "true" else { throw POSIXError(.EBUSY) }
    }
    /// Read the already-published immutable object from a retained timed-out run.
    /// This path only issues status, volume, lookup, and an R2 range GET.
    static func verifyRetained(runID: UUID, root: URL, connection: Connection) async throws -> URL {
        let (client, work, original) = try await retainedOwner(runID: runID, root: root)
        guard original.stage == "managed-publication",
              original.diagnostic == "posix-errno-" + String(ETIMEDOUT),
              original.passed.contains("immediate-pending-file-replace-retains-old-reader") else { throw POSIXError(.EINVAL) }
        let reply = try await client.call(.init(operation: "status"))
        guard let data = reply.data else { throw StorageFailure.integrity }
        let status = try JSONDecoder().decode(SyncEngineStatus.self, from: data)
        guard status.attention == 0, status.pending == 0,
              status.localRevision == status.publishedRevision else { throw StorageFailure.busy }
        try connection.validate()
        let scope = prefix(parent: connection.prefix, id: runID)
        let storage = R2StorageConfiguration(endpoint: connection.endpoint, bucket: connection.bucket, prefix: scope,
            accessKey: connection.accessKey, secretKey: connection.secretKey)
        let remote = try S3StorageRemote(configuration: storage, multipartDirectory: work.appendingPathComponent("Readback"))
        defer { remote.close() }
        var verified = original
        verified.sha256 = try await publishedHash(client: client, remote: remote, scope: scope)
        verified.state = "verified-after-deadline"
        verified.stage = "existing-published-content-readback"
        verified.mountMayRemain = false
        verified.passed += ["managed-revision-published-and-drained", "independent-r2-published-content-sha256"]
        let output = work.appendingPathComponent("readback-" + UUID().uuidString + ".json")
        try save(verified, output)
        return output
    }
    private static func projectSource(_ work: URL, seeded: Bool) -> URL {
        work.appendingPathComponent("CloudDrive-" + work.lastPathComponent + (seeded ? "-Group" : ".logicx"))
    }

    private static func seedGroup(work: URL, config: NamespaceEngineConfiguration, remote: S3StorageRemote, scope: String) async throws {
        let source = projectSource(work, seeded: true)
        let store = try NamespaceStore(directory: config.directory.appendingPathComponent("Namespace"), binding: config.binding, mode: .managed)
        var entries: [NamespaceImportEntry] = []
        for take in 0..<12 {
            let folder = source.appendingPathComponent("Take-\(take)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let payload = Data("CloudDrive grouping sample \(take)".utf8)
            let id = UUID()
            let object = try await remote.put(key: scope + "/.clouddrive/v1/content/" + id.uuidString,
                data: payload, condition: .absent, operationID: id)
            let backing = ObjectLocator(key: object.key, validator: object.validator, size: object.size, checksum: object.checksum)
            for index in 0..<(take < 9 ? 64 : 63) {
                let name = "Clip-\(index).bin"
                try payload.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
                entries.append(.init(path: source.lastPathComponent + "/Take-\(take)/" + name,
                    kind: .file, size: object.size, backing: backing))
            }
        }
        try await store.importEntries(entries)
        await store.close()
    }

    private static func projectExercise(work: URL, mount: URL, seeded: Bool) async throws {
        let source = projectSource(work, seeded: seeded)
        for index in 0..<12 where !seeded {
            let child = source.appendingPathComponent("Take-\(index)/Media")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let data = Data((0..<32768).map { UInt8(truncatingIfNeeded: $0 + index) })
            try data.write(to: child.appendingPathComponent("audio.bin"), options: .withoutOverwriting)
        }
        var ready = try JSONSerialization.data(withJSONObject: ["event": "finder-ready", "source": source.path, "mount": mount.path, "verifyLayout": seeded ? "grouped" : "original"])
        ready.append(10)
        try FileHandle.standardOutput.write(contentsOf: ready)
        let end = ContinuousClock.now.advanced(by: .seconds(seeded ? 1100 : 360))
        while !FileManager.default.fileExists(atPath: work.appendingPathComponent("finder-finished").path) {
            guard ContinuousClock.now < end else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func projectVerify(work: URL, client: UnixSocketRPCClient, remote: S3StorageRemote, scope: String, seeded: Bool) async throws -> Int {
        guard let volume = try await client.call(.init(operation: "volume")).volume else { throw StorageFailure.integrity }
        let root = volume.rootID
        let publisher = ManagedManifestPublisher(remote: remote, prefix: scope, volumeID: volume.id)
        let records = try await publisher.exportRecords()
        let published = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        func lookup(_ parent: UUID, _ name: String) async throws -> NamespaceNode {
            guard let node = try await client.call(.init(operation: "lookup", parentID: parent, name: name)).node,
                  let cold = published[node.id], cold.parentID == parent, cold.name == name,
                  cold.backing == node.backing, cold.xattrs == node.xattrs else { throw StorageFailure.integrity }
            return node
        }
        let source = projectSource(work, seeded: seeded)
        let project = try await lookup(root, source.lastPathComponent)
        let grouped = seeded ? try await lookup(project.id, "Grouped") : project
        var verified = 0
        for index in 0..<12 {
            let take = "Take-\(index)"
            let directory = try await lookup(grouped.id, take)
            if seeded {
                let reply = try await client.call(.init(operation: "list", parentID: directory.id, limit: 128))
                guard let nodes = reply.nodes else { throw StorageFailure.integrity }
                let clips = nodes.filter { $0.name.hasPrefix("Clip-") }
                let names = Set((0..<(index < 9 ? 64 : 63)).map { "Clip-\($0).bin" })
                guard Set(clips.map(\.name)) == names, let locator = clips.first?.backing,
                      clips.allSatisfy({ $0.backing == locator && published[$0.id]?.backing == locator && published[$0.id]?.parentID == directory.id && published[$0.id]?.name == $0.name }), let validator = locator.validator,
                      locator.key.hasPrefix(scope + "/.clouddrive/v1/content/") else { throw StorageFailure.integrity }
                let data = try await remote.read(key: locator.key, range: 0..<locator.size, validator: validator)
                guard data.data == Data("CloudDrive grouping sample \(index)".utf8), data.validator == validator else { throw StorageFailure.integrity }
                verified += clips.count
                continue
            }
            let media = try await lookup(directory.id, "Media")
            let node = try await lookup(media.id, "audio.bin")
            let expected = try Data(contentsOf: source.appendingPathComponent(take + "/Media/audio.bin"))
            guard let locator = node.backing, locator.key.hasPrefix(scope + "/.clouddrive/v1/content/"),
                  let validator = locator.validator, !validator.isEmpty, locator.size == expected.count else { throw StorageFailure.integrity }
            let got = try await remote.read(key: locator.key, range: 0..<locator.size, validator: validator)
            guard got.data == expected, got.validator == validator, got.totalSize == expected.count else { throw StorageFailure.integrity }
            verified += 1
        }
        return verified
    }
    struct Exercise: Codable { var mount: URL; var resource: URL; var identity: String }
    /// Private child mode receives only synthetic mount coordinates, never credentials.
    static func exercise() throws {
        let input = try FileHandle.standardInput.read(upToCount: 16_385) ?? Data()
        guard input.count <= 16_384 else { throw POSIXError(.EINVAL) }
        let request = try JSONDecoder().decode(Exercise.self, from: input)
        guard request.mount.lastPathComponent == "Mount", request.mount.deletingLastPathComponent().lastPathComponent.hasPrefix("native-"),
              request.mount.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Qualifications",
              let entry = MountInspector.exactEntry(at: request.mount.path, entries: try MountInspector.snapshot()),
              entry.id == request.identity, owned(entry, mount: request.mount, resource: request.resource) else { throw POSIXError(.EPERM) }
        try directory(request.mount.deletingLastPathComponent(), create: false)
        let original = request.mount.appendingPathComponent("sample.bin"), renamed = request.mount.appendingPathComponent("renamed.bin")
        let fd = Darwin.open(original.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false), expected = payload()
        try handle.write(contentsOf: expected); try handle.synchronize(); try handle.seek(toOffset: 0)
        guard try handle.readToEnd() == expected else { throw StorageFailure.integrity }
        // This UUID-scoped test volume starts empty. Do not overwrite another
        // entry or require a provider-specific exclusive-rename extension.
        var existing = stat()
        guard lstat(renamed.path, &existing) == -1, errno == ENOENT else { throw POSIXError(.EEXIST) }
        guard Darwin.rename(original.path, renamed.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let read = try FileHandle(forReadingFrom: renamed); defer { try? read.close() }
        guard try read.readToEnd() == expected else { throw StorageFailure.integrity }
        let replacement = request.mount.appendingPathComponent("replaced.bin")
        let oldFD = Darwin.open(replacement.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard oldFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(oldFD) }
        let oldReader = FileHandle(fileDescriptor: oldFD, closeOnDealloc: false)
        let oldBytes = Data("superseded fixture".utf8)
        try oldReader.write(contentsOf: oldBytes)
        try oldReader.synchronize()
        try oldReader.seek(toOffset: 0)
        guard Darwin.rename(renamed.path, replacement.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard try oldReader.readToEnd() == oldBytes else { throw StorageFailure.integrity }
        let surviving = try FileHandle(forReadingFrom: replacement)
        defer { try? surviving.close() }
        guard try surviving.readToEnd() == expected else { throw StorageFailure.integrity }
    }
}
#endif
