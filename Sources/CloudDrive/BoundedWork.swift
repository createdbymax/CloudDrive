import Foundation

/// A deadline for an OS call which has no cancellation API (for example Keychain).
/// Returning control does not pretend the OS call stopped; its result is discarded after timeout.
final class BoundedWork<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Result<Value, Error>) -> Void)?
    private var result: Result<Value, Error>?
    static func run(timeout: TimeInterval, _ work: @escaping () throws -> Value) async throws -> Value {
        let state = BoundedWork<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.install { continuation.resume(with: $0) }
                DispatchQueue.global(qos: .userInitiated).async {
                    do { state.finish(.success(try work())) } catch { state.finish(.failure(error)) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { state.finish(.failure(RuntimeFailure.timedOut)) }
            }
        }, onCancel: { state.finish(.failure(RuntimeFailure.cancelled)) })
    }
    private func install(_ callback: @escaping (Result<Value, Error>) -> Void) {
        lock.lock()
        if let result { lock.unlock(); callback(result) }
        else { self.callback = callback; lock.unlock() }
    }
    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let callback = callback; self.callback = nil
        lock.unlock(); callback?(result)
    }
}
