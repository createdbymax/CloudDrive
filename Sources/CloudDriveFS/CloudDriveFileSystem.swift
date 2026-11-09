import Foundation
import FSKit
import CloudDriveCore

/// A path resource contains a private authenticated owner descriptor, not bucket
/// credentials or a second filesystem database. Resource access lasts exactly as
/// long as the loaded volume.
@available(macOS 26.0, *)
public final class CloudDriveFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var resourceURL: URL?
    private var loadedVolume: CloudDriveFSVolume?

    public func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let resource = resource as? FSPathURLResource else { reply(nil, POSIXError(.ENODEV)); return }
        let url = resource.url
        guard url.startAccessingSecurityScopedResource() else { reply(nil, POSIXError(.EACCES)); return }
        Task {
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let descriptor = try NamespaceOwnerDescriptor.read(from: url.appendingPathComponent(".clouddrive-owner.json"))
                guard URL(fileURLWithPath: descriptor.socketPath).deletingLastPathComponent().resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else { throw POSIXError(.EACCES) }
                let response = try await UnixSocketRPCClient(descriptor: descriptor).call(NamespaceRPCRequest(operation: "volume"))
                guard let volume = response.volume, volume.binding == descriptor.binding else { throw POSIXError(.EACCES) }
                reply(.usable(name: "CloudDrive", containerID: FSContainerIdentifier(uuid: volume.id)), nil)
            } catch { reply(nil, error) }
        }
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (FSVolume?, Error?) -> Void) {
        guard let resource = resource as? FSPathURLResource else { reply(nil, POSIXError(.ENODEV)); return }
        // Formatting an owner resource could destroy accepted state. Never force it.
        guard !options.taskOptions.contains("-f") else { reply(nil, POSIXError(.ENOTSUP)); return }
        let url = resource.url
        guard url.startAccessingSecurityScopedResource() else { reply(nil, POSIXError(.EACCES)); return }
        let admitted = lock.withLock { () -> Bool in if resourceURL != nil { return false }; resourceURL = url; return true }
        guard admitted else { url.stopAccessingSecurityScopedResource(); reply(nil, POSIXError(.EBUSY)); return }
        Task {
            do {
                let descriptor = try NamespaceOwnerDescriptor.read(from: url.appendingPathComponent(".clouddrive-owner.json"))
                guard URL(fileURLWithPath: descriptor.socketPath).deletingLastPathComponent().resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else { throw POSIXError(.EACCES) }
                let client = UnixSocketRPCClient(descriptor: descriptor)
                let response = try await client.call(NamespaceRPCRequest(operation: "volume"))
                guard let volume = response.volume, volume.binding == descriptor.binding else { throw POSIXError(.EACCES) }
                let mounted = CloudDriveFSVolume(owner: client, volume: volume, readOnly: options.taskOptions.contains("--rdonly"))
                lock.withLock { loadedVolume = mounted }; containerStatus = .ready
                reply(mounted, nil)
            } catch {
                lock.withLock { resourceURL = nil; loadedVolume = nil }
                url.stopAccessingSecurityScopedResource(); containerStatus = .blocked(status: error as NSError)
                reply(nil, error)
            }
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        guard let resource = resource as? FSPathURLResource else { reply(POSIXError(.EINVAL)); return }
        let released = lock.withLock { () -> URL? in
            guard resourceURL == resource.url else { return nil }
            defer { resourceURL = nil; loadedVolume = nil }
            return resourceURL
        }
        guard let url = released else { reply(POSIXError(.EINVAL)); return }
        url.stopAccessingSecurityScopedResource()
        containerStatus = .notReady(status: POSIXError(.ENOTCONN) as NSError)
        reply(nil)
    }
}
