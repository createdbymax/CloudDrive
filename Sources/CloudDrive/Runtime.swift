import Foundation
import Darwin

/// Bounded command execution. Command output is data for a parser, never a user-facing diagnostic.
struct CommandSpec: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var timeout: TimeInterval
    var outputLimit: Int
    init(executable: URL, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 15, outputLimit: Int = 65_536) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.timeout = timeout; self.outputLimit = outputLimit
    }
}
struct CommandResult: Sendable {
    let exitCode: Int32
    let output: Data
    let outputTruncated: Bool
    var diagnostic: String { "Helper exited with status \(exitCode). Raw output omitted." }
}
enum RuntimeFailure: Error, LocalizedError, Equatable {
    case timedOut, cancelled, launchFailed(Int32), invalidCommand, invalidControlResponse, controlHTTP(Int), oversizedResponse
    var errorDescription: String? {
        switch self {
        case .timedOut: return "The operation exceeded its deadline. Pending local data is retained."
        case .cancelled: return "The operation was cancelled. Pending local data is retained."
        case .launchFailed(let code): return "The helper could not start (\(code))."
        case .invalidCommand: return "The helper command is invalid."
        case .invalidControlResponse: return "Upload status is unknown: the control response is invalid."
        case .controlHTTP(let code): return "Upload status is unknown: control request failed (\(code))."
        case .oversizedResponse: return "Upload status is unknown: the control response exceeded its size limit."
        }
    }
}

enum CommandRunner {
    static func run(_ spec: CommandSpec) async throws -> CommandResult {
        let execution = CommandExecution(spec: spec)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                execution.begin { continuation.resume(with: $0) }
            }
        }, onCancel: { execution.cancel() })
    }
}

/// Each helper gets its own process group, so shell descendants cannot outlive cancellation.
/// No waitpid or filesystem operation runs on the UI actor. Deadline completion never waits for exit.
private final class CommandExecution: @unchecked Sendable {
    private let spec: CommandSpec
    private let queue = DispatchQueue(label: "CloudDrive.command", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var pid: pid_t = 0
    private var finished = false
    private var completion: ((Result<CommandResult, Error>) -> Void)?
    private var timer: DispatchSourceTimer?
    private var descriptor: Int32 = -1
    private var bytes = Data()
    private var truncated = false
    init(spec: CommandSpec) { self.spec = spec }
    func begin(_ completion: @escaping (Result<CommandResult, Error>) -> Void) {
        queue.async {
            self.completion = completion
            self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
            if cancelled { self.finish(.failure(RuntimeFailure.cancelled)); return }
            self.launch()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async {
            guard self.completion != nil else { return }
            self.stopGroup()
            self.finish(.failure(RuntimeFailure.cancelled))
        }
    }
    private func launch() {
        guard spec.timeout.isFinite, spec.timeout > 0, spec.outputLimit >= 0,
              spec.executable.isFileURL, !spec.executable.path.contains("\0"),
              spec.arguments.allSatisfy({ !$0.contains("\0") }),
              spec.environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            finish(.failure(RuntimeFailure.invalidCommand)); return
        }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { finish(.failure(RuntimeFailure.launchFailed(errno))); return }
        descriptor = fds[0]
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Deliberately do not inherit the app's credentials, RC tokens or arbitrary environment.
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        environment.merge(spec.environment) { _, supplied in supplied }
        let argv = ([spec.executable.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&child, spec.executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
        } }
        close(fds[1])
        guard result == 0 else { finish(.failure(RuntimeFailure.launchFailed(result))); return }
        pid = child
        let deadline = DispatchTime.now() + spec.timeout
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [self] in
            drain()
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                drain()
                // WIFEXITED/WEXITSTATUS are C macros unavailable to Swift.
                let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                pid = 0
                finish(.success(CommandResult(exitCode: exit, output: bytes, outputTruncated: truncated)))
            } else if result == -1 {
                pid = 0; finish(.failure(RuntimeFailure.launchFailed(errno)))
            } else if DispatchTime.now() >= deadline {
                stopGroup(); finish(.failure(RuntimeFailure.timedOut))
            }
        }
        timer.resume()
    }
    private func drain() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bounded work per tick: an indefinitely noisy child cannot starve the deadline.
        for _ in 0..<32 {
            let n = read(descriptor, &buffer, buffer.count)
            guard n > 0 else { break }
            let remaining = max(0, spec.outputLimit - bytes.count)
            bytes.append(contentsOf: buffer.prefix(min(n, remaining)))
            if n > remaining { truncated = true }
        }
    }
    private func stopGroup() {
        guard pid > 0 else { return }
        let child = pid
        _ = kill(-child, SIGTERM)
        // Completion is bounded independently of this cleanup. Reap without blocking any actor.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
            // The unreaped direct child keeps this PID reserved even if it exited after SIGTERM.
            // Kill its group before reaping, including descendants that ignored SIGTERM.
            _ = kill(-child, SIGKILL)
            var status: Int32 = 0
            if waitpid(child, &status, WNOHANG) == 0 {
                _ = kill(child, SIGKILL)
                // Do not wait indefinitely for a process stuck inside a kernel filesystem call.
                for _ in 0..<100 {
                    if waitpid(child, &status, WNOHANG) != 0 { break }
                    usleep(10_000)
                }
            }
        }
        pid = 0
    }
    private func finish(_ result: Result<CommandResult, Error>) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        let callback = completion; completion = nil; callback?(result)
    }
}

struct VFSStats: Decodable, Sendable, Equatable {
    let fs: String
    let diskCache: DiskCacheStats
    let cacheOptions: CloudCachePolicy.CacheOptions?
    struct DiskCacheStats: Decodable, Sendable, Equatable {
        let path: String
        let uploadsQueued: Int
        let uploadsInProgress: Int
        let erroredFiles: Int
        let bytesUsed: Int64
        let outOfSpace: Bool
        var idle: Bool { uploadsQueued == 0 && uploadsInProgress == 0 && erroredFiles == 0 && !outOfSpace }
        private enum CodingKeys: String, CodingKey { case path, uploadsQueued, uploadsInProgress, erroredFiles, bytesUsed, outOfSpace }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            uploadsQueued = try c.decode(Int.self, forKey: .uploadsQueued)
            uploadsInProgress = try c.decode(Int.self, forKey: .uploadsInProgress)
            erroredFiles = try c.decode(Int.self, forKey: .erroredFiles)
            bytesUsed = try c.decode(Int64.self, forKey: .bytesUsed)
            outOfSpace = try c.decode(Bool.self, forKey: .outOfSpace)
            guard !path.isEmpty, uploadsQueued >= 0, uploadsInProgress >= 0, erroredFiles >= 0, bytesUsed >= 0 else {
                throw RuntimeFailure.invalidControlResponse
            }
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fs = try c.decode(String.self, forKey: .fs)
        diskCache = try c.decode(DiskCacheStats.self, forKey: .diskCache)
        cacheOptions = try c.decodeIfPresent(CloudCachePolicy.CacheOptions.self, forKey: .opt)
        guard !fs.isEmpty else { throw RuntimeFailure.invalidControlResponse }
    }
    private enum CodingKeys: String, CodingKey { case fs, diskCache, opt }
    static func decode(_ data: Data) throws -> VFSStats {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RuntimeFailure.invalidControlResponse }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct ControlClient: Sendable {
    let port: Int
    let username: String
    let token: String
    let timeout: TimeInterval
    private let sessionOwner: ControlSessionLifetime
    private var session: URLSession { sessionOwner.session }
    // Existing workers use this protocol username; recovery must keep authenticating.
    init(port: Int, username: String = "bucketdrive", token: String, timeout: TimeInterval = 3, configuration: URLSessionConfiguration? = nil) {
        self.port = port; self.username = username; self.token = token; self.timeout = timeout
        let config = configuration ?? .ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        sessionOwner = ControlSessionLifetime(URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil))
    }
    func stats() async throws -> VFSStats { try VFSStats.decode(await call(route: "vfs/stats")) }
    func pid() async throws -> Int32 {
        struct PIDResponse: Decodable { let pid: Int32 }
        let data = try await call(route: "core/pid")
        guard let result = try? JSONDecoder().decode(PIDResponse.self, from: data), result.pid > 0 else { throw RuntimeFailure.invalidControlResponse }
        return result.pid
    }
    func call(route: String, body: Data = Data("{}".utf8)) async throws -> Data {
        guard (1...65535).contains(port), timeout.isFinite, timeout > 0, !token.isEmpty,
              route.range(of: "^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw RuntimeFailure.invalidControlResponse }
        let url = URL(string: "http://127.0.0.1:\(port)/\(route)")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(username):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let operation = ControlRequest(session: session, request: request, timeout: timeout)
        let (data, response) = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in operation.start { continuation.resume(with: $0) } }
        }, onCancel: { operation.cancel() })
        guard let http = response as? HTTPURLResponse else { throw RuntimeFailure.invalidControlResponse }
        guard http.statusCode == 200 else { throw RuntimeFailure.controlHTTP(http.statusCode) }
        guard data.count <= 1_048_576 else { throw RuntimeFailure.oversizedResponse }
        return data
    }
}

/// An absolute deadline independent of URLSession's idle/resource timeout behavior.
private final class ControlRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private let request: URLRequest
    private let timeout: TimeInterval
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var callback: ((Result<(Data, URLResponse), Error>) -> Void)?
    private var done = false
    private var cancelled = false
    init(session: URLSession, request: URLRequest, timeout: TimeInterval) { self.session = session; self.request = request; self.timeout = timeout }
    func start(_ callback: @escaping (Result<(Data, URLResponse), Error>) -> Void) {
        lock.lock()
        self.callback = callback
        if cancelled { done = true; self.callback = nil; lock.unlock(); callback(.failure(RuntimeFailure.cancelled)); return }
        let task = session.dataTask(with: request) { [self] data, response, error in
            if let error = error as? URLError {
                finish(.failure(error.code == .timedOut ? RuntimeFailure.timedOut : RuntimeFailure.invalidControlResponse))
            } else if error != nil { finish(.failure(RuntimeFailure.invalidControlResponse)) }
            else if let data, let response { finish(.success((data, response))) }
            else { finish(.failure(RuntimeFailure.invalidControlResponse)) }
        }
        self.task = task
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(RuntimeFailure.timedOut), cancelTask: true) }
        self.deadline = deadline
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        task.resume()
    }
    func cancel() {
        lock.lock(); cancelled = true; let started = callback != nil; lock.unlock()
        if started { finish(.failure(RuntimeFailure.cancelled), cancelTask: true) }
    }
    private func finish(_ result: Result<(Data, URLResponse), Error>, cancelTask: Bool = false) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true; let callback = callback; self.callback = nil
        let task = task; self.task = nil; deadline?.cancel(); deadline = nil
        lock.unlock()
        if cancelTask { task?.cancel() }
        callback?(result)
    }
}

private final class ControlSessionLifetime: @unchecked Sendable {
    let session: URLSession
    init(_ session: URLSession) { self.session = session }
    deinit { session.invalidateAndCancel() }
}
