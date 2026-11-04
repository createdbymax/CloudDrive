import Foundation

/// Credentials authorized during this process are reused without another Keychain query.
/// Native OS requests cannot be interrupted. A deadline returns control while the request
/// remains exclusively owned; only an explicit load can consume a late interactive approval.
final class CredentialSession<Value: Equatable>: @unchecked Sendable {
    typealias Reader = (Bool) throws -> Value?
    typealias Writer = (Value) throws -> Void
    private enum Kind { case load(interactive: Bool), save(Value) }
    private final class Request {
        let id = UUID()
        let kind: Kind
        var callback: ((Result<Value?, Error>) -> Void)?
        var timer: DispatchWorkItem?
        var delivered = false
        var expired = false
        var cancelled = false
        init(_ kind: Kind) { self.kind = kind }
    }
    private struct LateApproval {
        let requestID: UUID
        let value: Value?
    }
    private let lock = NSLock()
    private let reader: Reader
    private let writer: Writer
    private let shouldCache: (Value) -> Bool
    private let executionQueue: DispatchQueue
    private var pending: Request?
    private var cached: Value?
    private var lateApproval: LateApproval?

    init(read: @escaping Reader, write: @escaping Writer, shouldCache: @escaping (Value) -> Bool = { _ in true }, executionQueue: DispatchQueue = .global(qos: .userInitiated)) {
        reader = read; writer = write; self.shouldCache = shouldCache; self.executionQueue = executionQueue
    }

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }; return pending != nil
    }

    func load(allowInteraction: Bool = false, timeout: TimeInterval? = nil) async throws -> Value? {
        try await execute(.load(interactive: allowInteraction), timeout: timeout ?? (allowInteraction ? 300 : 5))
    }

    func save(_ value: Value, timeout: TimeInterval = 5) async throws {
        _ = try await execute(.save(value), timeout: timeout)
    }

    /// Forget only in-process values. Never deletes or alters a Keychain item.
    /// A native request already in flight remains owned until it returns, but cannot recache.
    func clearMemory() {
        lock.lock()
        cached = nil; lateApproval = nil
        var callback: ((Result<Value?, Error>) -> Void)?
        if let request = pending {
            request.cancelled = true; request.timer?.cancel(); request.timer = nil
            if !request.delivered {
                request.delivered = true; callback = request.callback; request.callback = nil
            }
        }
        lock.unlock()
        callback?(.failure(RuntimeFailure.cancelled))
    }

    private func execute(_ kind: Kind, timeout: TimeInterval) async throws -> Value? {
        guard timeout.isFinite && timeout > 0 else {
            throw DriveError.message("The credential request deadline is invalid.")
        }
        let request = Request(kind)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(request, timeout: timeout) { continuation.resume(with: $0) }
            }
        }, onCancel: { self.cancel(request) })
    }

    private func start(_ request: Request, timeout: TimeInterval, completion: @escaping (Result<Value?, Error>) -> Void) {
        lock.lock()
        if request.cancelled {
            request.delivered = true; lock.unlock(); completion(.failure(RuntimeFailure.cancelled)); return
        }
        guard pending == nil else {
            request.delivered = true; lock.unlock(); completion(.failure(CredentialFailure.operationPending)); return
        }
        switch request.kind {
        case .load(let interactive):
            if let cached {
                request.delivered = true; lock.unlock(); completion(.success(cached)); return
            }
            if let approved = lateApproval {
                guard interactive else {
                    request.delivered = true; lock.unlock(); completion(.failure(CredentialFailure.authorizationNeeded)); return
                }
                cached = approved.value.flatMap { shouldCache($0) ? $0 : nil }; lateApproval = nil
                request.delivered = true; lock.unlock(); completion(.success(approved.value)); return
            }
        case .save(let value):
            if cached == value {
                request.delivered = true; lock.unlock(); completion(.success(value)); return
            }
            // A failed or abandoned changed write can have an uncertain backend outcome.
            // Do not subsequently serve an older value as though it were authoritative.
            cached = nil; lateApproval = nil
        }
        pending = request; request.callback = completion
        let timer = DispatchWorkItem { [weak self, weak request] in
            if let request { self?.expire(request) }
        }
        request.timer = timer
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        executionQueue.async { [self, request] in
            lock.lock()
            let cancelledBeforeNativeCall = request.cancelled, expiredBeforeNativeCall = request.expired
            lock.unlock()
            if cancelledBeforeNativeCall || expiredBeforeNativeCall {
                finishNative(request, result: .failure(cancelledBeforeNativeCall ? RuntimeFailure.cancelled : RuntimeFailure.timedOut)); return
            }
            let result: Result<Value?, Error>
            do {
                switch request.kind {
                case .load(let interactive): result = .success(try reader(interactive))
                case .save(let value): try writer(value); result = .success(value)
                }
            } catch { result = .failure(error) }
            finishNative(request, result: result)
        }
    }

    private func finishNative(_ request: Request, result: Result<Value?, Error>) {
        lock.lock()
        guard pending === request else { lock.unlock(); return }
        pending = nil; request.timer?.cancel(); request.timer = nil
        if request.delivered {
            if request.expired && !request.cancelled,
               case .load(interactive: true) = request.kind,
               case .success(let value) = result {
                lateApproval = LateApproval(requestID: request.id, value: value)
            }
            lock.unlock(); return
        }
        request.delivered = true
        if !request.cancelled, case .success(let value) = result { cached = value.flatMap { shouldCache($0) ? $0 : nil } }
        let callback = request.callback; request.callback = nil
        lock.unlock()
        callback?(result)
    }

    private func expire(_ request: Request) {
        lock.lock()
        guard pending === request, !request.delivered else { lock.unlock(); return }
        request.expired = true; request.delivered = true
        let callback = request.callback; request.callback = nil
        request.timer = nil
        lock.unlock()
        callback?(.failure(RuntimeFailure.timedOut))
    }

    private func cancel(_ request: Request) {
        lock.lock()
        request.cancelled = true
        if lateApproval?.requestID == request.id { lateApproval = nil }
        guard !request.delivered else { lock.unlock(); return }
        request.delivered = true; request.timer?.cancel(); request.timer = nil
        let callback = request.callback; request.callback = nil
        lock.unlock()
        callback?(.failure(RuntimeFailure.cancelled))
    }
}
