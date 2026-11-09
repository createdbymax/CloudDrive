import Foundation
import Darwin
import Security
import CryptoKit

public struct NamespaceOwnerDescriptor: Codable, Sendable {
    public let protocolVersion: Int
    /// Absent on older owners; never send an extended frame to one.
    public let rawWriteLimit: Int?
    public static let maximumWriteBytes = 8 * 1024 * 1024
    public let socketPath: String
    public let token: String
    public let binding: String
    public let sessionID: UUID
    public init(socketPath: String, token: String, binding: String, sessionID: UUID = UUID()) {
        rawWriteLimit = Self.maximumWriteBytes; protocolVersion = 1; self.socketPath = socketPath; self.token = token; self.binding = binding; self.sessionID = sessionID
    }
    public static func read(from url: URL) throws -> Self {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16_384 else { throw POSIXError(.EPERM) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try file.read(upToCount: 16_385) ?? Data()
        guard bytes.count == info.st_size else { throw POSIXError(.EPROTO) }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validateShape()
        return value
    }
    fileprivate func validateShape() throws {
        let characters = Array(token.utf8)
        guard protocolVersion == 1, characters.count == 64,
              characters.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              socketPath.hasPrefix("/"), !socketPath.contains("\0"), socketPath.utf8.count < 104,
              !binding.isEmpty, !binding.contains("\0"), binding.utf8.count <= 1024 else { throw POSIXError(.EPROTO) }
    }
    public func save(in directory: URL) throws {
        try validateShape()
        let final = directory.appendingPathComponent(".clouddrive-owner.json")
        let temp = directory.appendingPathComponent(".owner-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd); unlink(temp.path) }
        let bytes = try JSONEncoder().encode(self)
        try SocketFrames.writeAll(fd, bytes)
        guard fsync(fd) == 0, rename(temp.path, final.path) == 0 else { throw POSIXError(.EIO) }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }
    public static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw POSIXError(.EIO) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A kernel-derived process incarnation, never decoded from client JSON.
/// Recycled PIDs do not inherit the previous client's generation leases.
public struct NamespaceRPCPeer: Codable, Hashable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public static func capture(pid: Int32) throws -> Self {
        guard pid > 1 else { throw POSIXError(.EPERM) }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        guard count == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid(), info.pbi_status != SZOMB else { throw POSIXError(.EPERM) }
        return Self(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
    public var matchesRunningProcess: Bool { (try? Self.capture(pid: pid)) == self }
    /// Failure to inspect a process is unknown, not proof it died. A changed
    /// start time proves PID reuse; a changed UID alone does not prove exit.
    public var hasDefinitelyExited: Bool {
        if Darwin.kill(pid, 0) == -1, Darwin.errno == ESRCH { return true }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        guard count == MemoryLayout.size(ofValue: info) else { return false }
        if info.pbi_start_tvsec != startSeconds || info.pbi_start_tvusec != startMicroseconds { return true }
        return info.pbi_uid == uid && info.pbi_status == SZOMB
    }
}

public struct NamespaceRPCRequest: Codable, Sendable {
    /// The transport overwrites this field only after checking kernel peer
    /// credentials and code identity. It is deliberately absent from CodingKeys.
    public internal(set) var trustedPeer: NamespaceRPCPeer? = nil
    enum CodingKeys: String, CodingKey {
        case protocolVersion, requestID, authToken, operation, nodeID, parentID, name
        case destinationParentID, destinationName, offset, length, data, generation
        case cookie, limit, replace, kind, attributes, handleID
    }
    public var protocolVersion = 1
    public var requestID = UUID()
    public var authToken: String?
    public var operation: String
    public var nodeID: UUID?
    public var parentID: UUID?
    public var name: String?
    public var destinationParentID: UUID?
    public var destinationName: String?
    public var offset: Int64?
    public var length: Int?
    public var data: Data?
    public var generation: Int64?
    public var cookie: String?
    public var limit: Int?
    public var replace: Bool?
    public var kind: NamespaceNodeKind?
    public var attributes: [String: String]?
    public var handleID: UUID?
    public init(operation: String, nodeID: UUID? = nil, parentID: UUID? = nil, name: String? = nil,
                destinationParentID: UUID? = nil, destinationName: String? = nil, offset: Int64? = nil,
                length: Int? = nil, data: Data? = nil, generation: Int64? = nil, cookie: String? = nil,
                limit: Int? = nil, replace: Bool? = nil, kind: NamespaceNodeKind? = nil,
                attributes: [String: String]? = nil, handleID: UUID? = nil) {
        self.operation = operation; self.nodeID = nodeID; self.parentID = parentID; self.name = name
        self.destinationParentID = destinationParentID; self.destinationName = destinationName
        self.offset = offset; self.length = length; self.data = data; self.generation = generation
        self.cookie = cookie; self.limit = limit; self.replace = replace; self.kind = kind
        self.attributes = attributes; self.handleID = handleID
    }
}

public struct NamespaceRPCError: Codable, Sendable {
    public let errno: Int32
    public let message: String
    public init(errno: Int32, message: String) { self.errno = errno; self.message = message }
}
public struct NamespaceRPCResponse: Codable, Sendable {
    public var requestID: UUID
    public var node: NamespaceNode?
    public var nodes: [NamespaceNode]?
    public var volume: NamespaceVolume?
    public var data: Data?
    public var revision: Int64?
    public var nextCookie: String?
    public var error: NamespaceRPCError?
    public var generation: Int64?
    public var handleID: UUID?
    public var attributes: [String: String]?
    public init(requestID: UUID) { self.requestID = requestID }
    public static func failure(_ request: NamespaceRPCRequest, error: Error) -> Self {
        var result = Self(requestID: request.requestID)
        let code: Int32, kind: String, message: String
        switch error {
        case NamespaceExportFailure.finderMetadata:
            code = ENOTSUP; kind = "export.finderMetadata"
            message = NamespaceExportFailure.finderMetadataMessage
        case let failure as StorageFailure:
            switch failure {
            case .notFound: code = ENOENT; kind = "storage.notFound"; message = "The requested cloud object is unavailable."
            case .conflict: code = ESTALE; kind = "storage.conflict"; message = "Cloud data changed. Both versions were preserved; review the conflict before retrying."
            case .unknownOutcome: code = EIO; kind = "storage.unknownOutcome"; message = "CloudDrive could not confirm the cloud result. Keep its recovery records and retry recovery."
            case .invalidResponse: code = EPROTO; kind = "storage.invalidResponse"; message = "Cloud storage returned an invalid response. Recovery records were preserved."
            case .offline: code = ENETUNREACH; kind = "storage.offline"; message = "Cloud storage is unreachable. Accepted local changes were preserved."
            case .unsupported: code = ENOTSUP; kind = "storage.unsupported"; message = "The currently qualified backend does not support this storage operation. Retained data was preserved."
            case .invalidRange: code = EINVAL; kind = "storage.invalidRange"; message = "The requested file range could not be verified."
            case .fileTooLarge: code = EFBIG; kind = "storage.fileTooLarge"; message = "This file exceeds the maximum supported upload size."
            case .localStorageFull: code = ENOSPC; kind = "storage.localStorageFull"; message = "Local staging has insufficient space. Free eligible local space or finish pending uploads."
            case .integrity: code = EIO; kind = "storage.integrity"; message = "CloudDrive could not verify retained data. Review recovery before retrying."
            case .busy: code = EBUSY; kind = "storage.busy"; message = "An active storage operation prevents this change. Wait for it to finish and retry."
            }
        case let failure as NamespaceFailure:
            // NamespaceFailure has no associated/private values. Its declared case
            // name is a fixed diagnostic code, never a provider error description.
            kind = "namespace." + String(describing: failure)
            switch failure {
            case .notFound, .operationNotFound: code = ENOENT
            case .collision: code = EEXIST
            case .notDirectory: code = ENOTDIR
            case .isDirectory: code = EISDIR
            case .directoryNotEmpty: code = ENOTEMPTY
            case .invalidName, .cycle, .invalidTransition: code = EINVAL
            case .rootProtected, .ownership, .bindingMismatch: code = EPERM
            case .generationChanged: code = ESTALE
            case .limitExceeded: code = ENOSPC
            case .incompatibleSchema: code = EPROTO
            case .storage, .corrupt: code = EIO
            }
            switch failure {
            case .bindingMismatch: message = "Recovery records belong to another drive. Select the matching connection."
            case .incompatibleSchema: message = "These recovery records need a compatible CloudDrive version. No data was replaced."
            case .notFound, .operationNotFound: message = "The requested item or operation is no longer available."
            case .ownership: message = "The storage owner's identity could not be confirmed. Use recovery before reconnecting."
            case .corrupt, .storage: message = "CloudDrive could not verify local recovery state. Retained data was preserved."
            case .generationChanged: message = "The file changed during this operation. Retained versions were preserved."
            default: message = "The namespace change could not be accepted. Retained data was preserved."
            }
        case let value as POSIXError:
            code = value.code.rawValue; kind = "posix." + String(code)
            switch value.code {
            case .EROFS: message = "This drive is in read-only preview. Detach it before enabling writes."
            case .EBUSY: message = "An active operation or open handle prevents this change. Wait and retry."
            case .ENOSPC: message = "There is insufficient local space to accept this change."
            case .EPERM, .EACCES: message = "The operation's ownership or authorization could not be verified."
            default: message = "The filesystem operation could not be completed. Retained data was preserved."
            }
        default:
            code = EIO; kind = "internal.unclassified"; message = "The filesystem operation could not be completed. Retained data was preserved."
        }
        result.error = .init(errno: code, message: message)
        result.attributes = ["failureKind": kind]
        return result
    }
}

private enum SocketFrames {
    static let maximum = 4 * 1_048_576
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un(); value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return value
    }
    static func socket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && Darwin.errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }; offset += count
            }
        }
    }
    static func readAll(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let got = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                if got < 0 && Darwin.errno == EINTR { continue }
                guard got > 0 else { throw POSIXError(.ECONNRESET) }; offset += got
            }
        }
        return data
    }
    static func send<T: Encodable>(_ value: T, fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximum else { throw POSIXError(.EMSGSIZE) }
        var length = UInt32(data.count).bigEndian
        try writeAll(fd, withUnsafeBytes(of: &length) { Data($0) }); try writeAll(fd, data)
    }
    private static let binaryFlag: UInt32 = 0x80000000
    static func sendRequest(_ request: NamespaceRPCRequest, fd: Int32, rawLimit: Int?) throws {
        guard request.operation == "write", let bytes = request.data, bytes.count >= 16_384,
              let rawLimit, bytes.count <= min(rawLimit, NamespaceOwnerDescriptor.maximumWriteBytes) else {
            try send(request, fd: fd); return
        }
        var header = request; header.data = nil
        let json = try JSONEncoder().encode(header)
        guard !json.isEmpty, json.count <= 65536 else { throw POSIXError(.EMSGSIZE) }
        var lengths = [(binaryFlag | UInt32(json.count)).bigEndian, UInt32(bytes.count).bigEndian]
        try lengths.withUnsafeMutableBytes { try writeAll(fd, Data($0)) }
        try writeAll(fd, json); try writeAll(fd, bytes)
    }
    static func receiveRequest(fd: Int32) throws -> NamespaceRPCRequest {
        let flagAndLength = try readAll(fd, count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let binary = flagAndLength & binaryFlag != 0
        let length = Int(flagAndLength & ~binaryFlag)
        guard length > 0, length <= (binary ? 65536 : maximum) else { throw POSIXError(.EMSGSIZE) }
        if !binary { return try JSONDecoder().decode(NamespaceRPCRequest.self, from: readAll(fd, count: length)) }
        let payload = Int(try readAll(fd, count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard (1...NamespaceOwnerDescriptor.maximumWriteBytes).contains(payload) else { throw POSIXError(.EMSGSIZE) }
        var request = try JSONDecoder().decode(NamespaceRPCRequest.self, from: readAll(fd, count: length))
        guard request.operation == "write", request.data == nil else { throw POSIXError(.EPROTO) }
        request.data = try readAll(fd, count: payload)
        return request
    }
    static func receive<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
        let header = try readAll(fd, count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximum else { throw POSIXError(.EMSGSIZE) }
        return try JSONDecoder().decode(type, from: readAll(fd, count: Int(length)))
    }
}

private enum RPCLanes {
    static let metadataOperations: Set<String> = ["volume", "node", "lookup", "list", "search", "path", "events", "status", "capacity", "importProgress", "exportProgress", "pinStatus", "open", "close", "attach", "detach", "prepareStop", "enableWrites", "pause", "create", "rename", "remove", "setattrs"]
    static func metadata(_ request: NamespaceRPCRequest) -> Bool { metadataOperations.contains(request.operation) }
}

public struct UnixSocketRPCClient: Sendable {
    public let descriptor: NamespaceOwnerDescriptor
    private static let metadataSlots = DispatchSemaphore(value: 8)
    private static let ioSlots = DispatchSemaphore(value: 16)
    public init(descriptor: NamespaceOwnerDescriptor) { self.descriptor = descriptor }
    public func call(_ request: NamespaceRPCRequest) async throws -> NamespaceRPCResponse {
        try descriptor.validateShape()
        let cancellation = RPCSocketCancellation()
        return try await withTaskCancellationHandler {
            var lastBusy = NamespaceRPCResponse.failure(request, error: POSIXError(.EBUSY))
            lastBusy.attributes?["failureKind"] = "transport.busy"
            for attempt in 0..<8 {
                try Task.checkCancellation()
                let lane = RPCLanes.metadata(request) ? Self.metadataSlots : Self.ioSlots
                if lane.wait(timeout: .now()) == .success {
                    let response: NamespaceRPCResponse
                    do { response = try await exchange(request, cancellation: cancellation); lane.signal() }
                    catch { lane.signal(); throw error }
                    if response.error?.errno == EBUSY { lastBusy = response }
                    else { return try Self.checked(response) }
                }
                if attempt < 7 {
                    let milliseconds = min(128, 8 << attempt) + Int.random(in: 0...8)
                    try await Task.sleep(for: .milliseconds(milliseconds))
                }
            }
            return try Self.checked(lastBusy)
        } onCancel: { cancellation.cancel() }
    }
    private static func checked(_ response: NamespaceRPCResponse) throws -> NamespaceRPCResponse {
        if let error = response.error {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error.errno), userInfo: [NSLocalizedDescriptionKey: error.message, "failureKind": response.attributes?["failureKind"] ?? "internal.unclassified", "requestID": response.requestID.uuidString])
        }
        return response
    }
    private func exchange(_ original: NamespaceRPCRequest, cancellation: RPCSocketCancellation) async throws -> NamespaceRPCResponse {
        let descriptor = descriptor
        // Blocking socket calls run on bounded GCD lanes, never Swift's cooperative
        // executor. Paused content reads cannot starve metadata actor callbacks.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: RPCLanes.metadata(original) ? .userInitiated : .utility).async {
                do {
                    var request = original; request.authToken = descriptor.token
                    let fd = try SocketFrames.socket()
                    guard cancellation.register(fd) else { Darwin.close(fd); throw CancellationError() }
                    defer { cancellation.unregister(fd); Darwin.close(fd) }
                    var address = try SocketFrames.address(descriptor.socketPath)
                    let result = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                    }
                    // Preserve the kernel cause (for example sandbox EPERM or missing ENOENT).
                    // Reporting every connection failure as refusal hid FSKit activation failures.
                    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO) }
                    var uid: uid_t = 0, gid: gid_t = 0
                    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw POSIXError(.EPERM) }
                    if ["import", "seedManaged"].contains(request.operation) {
                        var timeout = timeval(tv_sec: 3600, tv_usec: 0)
                        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else { throw POSIXError(.EIO) }
                    }
                    try SocketFrames.sendRequest(request, fd: fd, rawLimit: descriptor.rawWriteLimit)
                    let response = try SocketFrames.receive(NamespaceRPCResponse.self, fd: fd)
                    guard response.requestID == request.requestID else { throw POSIXError(.EPROTO) }
                    if cancellation.isCancelled { throw CancellationError() }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: cancellation.isCancelled ? CancellationError() : error)
                }
            }
        }
    }
}

private final class RPCSocketCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func register(_ fd: Int32) -> Bool { lock.withLock { if cancelled { return false }; descriptor = fd; return true } }
    func unregister(_ fd: Int32) { lock.withLock { if descriptor == fd { descriptor = -1 } } }
    func cancel() { lock.withLock { cancelled = true; if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) } } }
}

/// One owner accepts bounded requests. The private descriptor is a capability; production
/// peers additionally need a valid signature from the same team with a known identifier.
public final class UnixSocketRPCServer: @unchecked Sendable {
    private let descriptor: NamespaceOwnerDescriptor
    private let handler: @Sendable (NamespaceRPCRequest) async -> NamespaceRPCResponse
    private let requireSignedPeers: Bool
    private let peerRequirement: SecRequirement?
    private let signatureLock = NSLock()
    private var signedGuests: [Data: SecCode] = [:]
    private let admission = DispatchSemaphore(value: 48)
    private let metadataAdmission = DispatchSemaphore(value: 8)
    private let ioAdmission = DispatchSemaphore(value: 16)
    private let stateLock = NSLock()
    private var listening: Int32 = -1
    private var stopping = false
    private var peers: Set<Int32> = []
    public init(descriptor: NamespaceOwnerDescriptor, requireSignedPeers: Bool = true,
                handler: @escaping @Sendable (NamespaceRPCRequest) async -> NamespaceRPCResponse) {
        self.descriptor = descriptor; self.handler = handler; self.requireSignedPeers = requireSignedPeers
        self.peerRequirement = requireSignedPeers ? Self.makePeerRequirement() : nil
    }
    /// Stop transport admission and interrupt blocked socket I/O. Already accepted
    /// owner work is not cancelled or treated as rolled back; it stays journaled.
    public func stop() {
        stateLock.withLock {
            stopping = true
            // Keep registration locked while signaling: a closed descriptor must
            // not be reused by another thread before it receives shutdown.
            for fd in (listening >= 0 ? [listening] : []) + Array(peers) { _ = shutdown(fd, SHUT_RDWR) }
        }
    }
    public func run() throws {
        try descriptor.validateShape()
        let parent = URL(fileURLWithPath: descriptor.socketPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
        guard lstat(descriptor.socketPath, &info) != 0, Darwin.errno == ENOENT else { throw POSIXError(.EADDRINUSE) }
        let fd = try SocketFrames.socket()
        let admitted = stateLock.withLock { () -> Bool in
            guard listening < 0, !stopping else { return false }; listening = fd; return true
        }
        guard admitted else { Darwin.close(fd); throw POSIXError(.ECANCELED) }
        var socketIdentity: (device: dev_t, inode: ino_t)?
        defer {
            stateLock.withLock { if listening == fd { listening = -1 } }
            Darwin.close(fd)
            var current = stat()
            if let original = socketIdentity, lstat(descriptor.socketPath, &current) == 0,
               current.st_dev == original.device, current.st_ino == original.inode { unlink(descriptor.socketPath) }
        }
        var address = try SocketFrames.address(descriptor.socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EIO) }
        if lstat(descriptor.socketPath, &info) == 0 { socketIdentity = (info.st_dev, info.st_ino) }
        guard chmod(descriptor.socketPath, 0o600) == 0, listen(fd, 16) == 0 else { throw POSIXError(.EIO) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        while !stateLock.withLock({ stopping }) {
            // Darwin does not reliably wake a blocking accept when another
            // thread shuts down a listening Unix socket. Poll bounds shutdown.
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, 250)
            if ready < 0 { if Darwin.errno == EINTR { continue }; throw POSIXError(.EIO) }
            if ready == 0 || stateLock.withLock({ stopping }) { continue }
            let peer = accept(fd, nil, nil)
            if peer < 0 {
                if stateLock.withLock({ stopping }) { return }
                if [EINTR, EAGAIN, EWOULDBLOCK].contains(Darwin.errno) { continue }
                throw POSIXError(.EIO)
            }
            guard admission.wait(timeout: .now()) == .success else { Darwin.close(peer); continue }
            let register = stateLock.withLock { () -> Bool in guard !stopping else { return false }; peers.insert(peer); return true }
            guard register else { admission.signal(); Darwin.close(peer); return }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { _ = stateLock.withLock { peers.remove(peer) }; admission.signal(); Darwin.close(peer) }
                // Darwin accepts inherit listener nonblocking state. Framed workers use
                // bounded socket deadlines and must wait for the complete request.
                let flags = fcntl(peer, F_GETFL)
                guard flags >= 0, fcntl(peer, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return }
                var enabled: Int32 = 1; _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
                var timeout = timeval(tv_sec: 60, tv_usec: 0)
                _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                _ = setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                do {
                    let identity = try Self.kernelPeer(peer)
                    guard !requireSignedPeers || signedPeer(peer, expected: identity),
                          identity.matchesRunningProcess else { throw POSIXError(.EPERM) }
                    var request = try SocketFrames.receiveRequest(fd: peer)
                    guard request.protocolVersion == 1, Self.equal(request.authToken ?? "", descriptor.token) else { throw POSIXError(.EACCES) }
                    request.trustedPeer = identity  // Serialized client fields cannot supply this identity.
                    let lane = RPCLanes.metadata(request) ? metadataAdmission : ioAdmission
                    guard lane.wait(timeout: .now()) == .success else {
                        var busy = NamespaceRPCResponse.failure(request, error: POSIXError(.EBUSY))
                        busy.attributes?["failureKind"] = "transport.busy"
                        try SocketFrames.send(busy, fd: peer)
                        return
                    }
                    defer { lane.signal() }
                    let complete = DispatchSemaphore(value: 0), box = RPCReplyBox()
                    Task { [request] in box.store(await handler(request)); complete.signal() }
                    complete.wait()
                    if let response = box.load() { try SocketFrames.send(response, fd: peer) }
                } catch { /* Close malformed/unauthenticated peers without reflecting private details. */ }
            }
        }
    }
    private static func kernelPeer(_ fd: Int32) throws -> NamespaceRPCPeer {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { throw POSIXError(.EPERM) }
        let result = try NamespaceRPCPeer.capture(pid: pid)
        guard result.uid == uid else { throw POSIXError(.EPERM) }; return result
    }
    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(SHA256.hash(data: Data(lhs.utf8))), b = Array(SHA256.hash(data: Data(rhs.utf8)))
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func makePeerRequirement() -> SecRequirement? {
        var own: SecCode?, ownStatic: SecStaticCode?, ownInfo: CFDictionary?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo) == errSecSuccess,
              let info = ownInfo as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        let rule = """
            anchor apple generic and certificate leaf[subject.OU] = "\(team)" and
            (identifier "local.bucketdrive.app" or identifier "local.bucketdrive.app.filesystem" or identifier "local.bucketdrive.app.engine")
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private func signedPeer(_ fd: Int32, expected: NamespaceRPCPeer) -> Bool {
        // The kernel supplies the complete token, including the exec incarnation.
        // PID alone survives exec and must never key an authorization cache.
        var token = audit_token_t(), length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard let peerRequirement, getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size, Int32(bitPattern: token.val.5) == expected.pid else { return false }
        let key = withUnsafeBytes(of: token) { Data($0) }
        return signatureLock.withLock {
            var guest = signedGuests[key]
            if guest == nil {
                guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: key] as CFDictionary, [], &guest) == errSecSuccess else { return false }
            }
            // Recheck the running code and signing requirement on every connection;
            // only the resolved SecCode handle is reused. A revoked/invalidated guest
            // can never get an affirmative cached authorization decision.
            guard let guest, SecCodeCheckValidity(guest, [], peerRequirement) == errSecSuccess else {
                signedGuests.removeValue(forKey: key)
                return false
            }
            if signedGuests[key] == nil {
                if signedGuests.count >= 16 { signedGuests.removeAll(keepingCapacity: true) }
                signedGuests[key] = guest
            }
            return true
        }
    }

}

private final class RPCReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NamespaceRPCResponse?
    func store(_ response: NamespaceRPCResponse) { lock.withLock { value = response } }
    func load() -> NamespaceRPCResponse? { lock.withLock { value } }
}
