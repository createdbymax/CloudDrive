import Foundation
import Darwin
import CloudDriveCore

@main struct CloudDriveEngineMain {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--version") { print("CloudDriveEngine namespace-v1"); return }
            if CommandLine.arguments == [CommandLine.arguments[0], "--resource-base"] {
                print(try NamespaceResourceLocation.sharedBase().path); return
            }
            guard CommandLine.arguments == [CommandLine.arguments[0], "--serve"] else { throw POSIXError(.EINVAL) }
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
                input.append(chunk); guard input.count <= 65_536 else { throw POSIXError(.EMSGSIZE) }
            }
            guard !input.isEmpty, input.count <= 65_536 else { throw POSIXError(.EMSGSIZE) }
            let config = try JSONDecoder().decode(NamespaceEngineConfiguration.self, from: input)
            guard !config.binding.isEmpty, config.storage == nil || config.fixtureDirectory == nil else { throw POSIXError(.EINVAL) }
            let managedThroughput = config.mode == .managed && config.storage != nil
            let transport: any StorageRemote
            if let storage = config.storage {
                guard !storage.allowLoopbackFixture else { throw POSIXError(.EPERM) }
                let multipart = config.directory.appendingPathComponent("Multipart")
                #if DEBUG
                if config.binding.hasPrefix("native-qualification-"),
                   let port = ProcessInfo.processInfo.environment["CLOUDDRIVE_QUALIFICATION_R2_TUNNEL"].flatMap(UInt16.init) {
                    transport = try S3StorageRemote(qualification: storage, multipartDirectory: multipart, port: port, managedThroughput: managedThroughput)
                } else {
                    transport = try S3StorageRemote(configuration: storage, multipartDirectory: multipart, managedThroughput: managedThroughput)
                }
                #else
                transport = try S3StorageRemote(configuration: storage, multipartDirectory: multipart, managedThroughput: managedThroughput)
                #endif
            } else if let fixture = config.fixtureDirectory { transport = try FixtureStorageRemote(directory: fixture) }
            else { throw POSIXError(.EINVAL) }
            let prefix = config.storage?.prefix ?? "fixture"
            let uploadRate = config.uploadRateBytesPerSecond ?? 0
            guard (0...UploadBandwidthLimiter.maximumRate).contains(uploadRate) else { throw StorageFailure.invalidRange }
            let uploadBandwidthLimiter = UploadBandwidthLimiter(initialBytesPerSecond: uploadRate)
            let limitedTransport = BandwidthLimitedStorageRemote(base: transport, limiter: uploadBandwidthLimiter)
            let remote: any StorageRemote
            if let encoded = config.encryptionKeyBase64 {
                guard config.mode == .managed, let keyID = config.encryptionKeyID,
                      let key = Data(base64Encoded: encoded), key.count == 32,
                      EncryptedDriveKey.identifier(for: key) == keyID else { throw StorageFailure.integrity }
                if config.restoreManaged != true && !FileManager.default.fileExists(atPath: config.directory.appendingPathComponent("Namespace").path) {
                    let page = try await transport.list(prefix: prefix + "/", cursor: nil, limit: 1)
                    guard page.objects.isEmpty, page.nextCursor == nil else { throw StorageFailure.unsupported }
                }
                try EncryptedDriveState.validate(directory: config.directory, binding: config.binding, keyID: keyID)
                remote = try EncryptedStorageRemote(base: limitedTransport, masterKey: key, keyID: keyID, prefix: prefix,
                    journalDirectory: config.directory.appendingPathComponent("Encryption"))
            } else {
                guard config.encryptionKeyID == nil else { throw StorageFailure.integrity }
                try EncryptedDriveState.validate(directory: config.directory, binding: config.binding, keyID: nil)
                remote = limitedTransport
            }
            let store: NamespaceStore
            if config.restoreManaged == true {
                guard config.mode == .managed, config.readOnly else { throw POSIXError(.EPERM) }
                store = try await NamespaceRecovery.restoreManaged(remote: remote, prefix: prefix, directory: config.directory, binding: config.binding)
            } else {
                store = try NamespaceStore(directory: config.directory.appendingPathComponent("Namespace"), binding: config.binding, mode: config.mode)
            }
            // Prefer direct publication from durable local extents while there
            // is room. Full-disk pressure still falls back to verified spill.
            let content = try ContentStore(directory: config.directory.appendingPathComponent("Content"),
                writebackWindow: managedThroughput ? 16 * 1024 * 1024 * 1024 : 256 * 1024 * 1024,
                packingJobs: managedThroughput ? 20 : 4)
            let cache = try RangeCache(directory: config.directory.appendingPathComponent("Cache"))
            let r2 = transport as? S3StorageRemote
            let sync = SyncEngine(store: store, content: content, cache: cache, remote: remote, prefix: prefix, mode: config.mode,
                uploadBytesPerSecond: { r2?.uploadBytesPerSecond() })
            let migration = NamespaceMigration(store: store, remote: remote, prefix: prefix, directory: config.directory)
            let exporter = NamespaceExporter(store: store, content: content, remote: remote, prefix: prefix, directory: config.directory.appendingPathComponent("Exports"))
            let owner = NamespaceOwner(store: store, sync: sync, directory: config.directory, readOnly: config.readOnly, migration: migration, exporter: exporter, uploadBandwidthLimiter: uploadBandwidthLimiter)
            let resource = try config.resourceDirectory ?? NamespaceResourceLocation.resource(sessionID: config.sessionID ?? UUID(), fixture: config.fixtureDirectory != nil)
            let base = resource.deletingLastPathComponent()
            let sharedBase = try? NamespaceResourceLocation.sharedBase()
            let isShared = sharedBase?.standardizedFileURL.path == base.standardizedFileURL.path
            let isFixture = config.fixtureDirectory != nil && base.standardizedFileURL.path == NamespaceResourceLocation.fixtureBase().standardizedFileURL.path
            guard isShared || isFixture else { throw POSIXError(.EPERM) }
            try privateDirectory(base)
            try privateDirectory(resource)
            let descriptor = try NamespaceOwnerDescriptor(socketPath: resource.appendingPathComponent("owner.sock").path,
                token: NamespaceOwnerDescriptor.randomToken(), binding: config.binding, sessionID: config.sessionID ?? UUID())
            try descriptor.save(in: resource)
            let server = UnixSocketRPCServer(descriptor: descriptor, requireSignedPeers: config.fixtureDirectory == nil) { request in await EngineTrace.measure("rpc.\(request.operation)") { await owner.handle(request) } }
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    await owner.backgroundStep()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            if managedThroughput {
                Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        await owner.backgroundPayloadStep()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            print(String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)); fflush(stdout)
            try await Task.detached { try server.run() }.value
        } catch {
            // No credentials, private filenames, raw provider response or command arguments.
            fputs("CloudDriveEngine could not start or retain its owned state. Recovery records were preserved.\n", stderr)
            exit(1)
        }
    }
    private static func privateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
    }
}
