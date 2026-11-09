import Foundation

/// A short, monotonic average of request-body bytes sent across all R2 sessions.
final class UploadThroughput: @unchecked Sendable {
    private static let nanosPerSecond: UInt64 = 1_000_000_000
    private let lock = NSLock()
    private var buckets: [UInt64: Double] = [:]

    func record(_ bytes: Int64) {
        guard bytes > 0 else { return }
        lock.withLock {
            let second = DispatchTime.now().uptimeNanoseconds / Self.nanosPerSecond
            if buckets[second] == nil {
                buckets = buckets.filter { second - $0.key < 4 }
            }
            buckets[second, default: 0] += Double(bytes)
        }
    }

    func bytesPerSecond() -> Double {
        lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            let second = now / Self.nanosPerSecond
            let bytes = buckets.reduce(0.0) { $0 + (second - $1.key < 4 ? $1.value : 0) }
            // Average the last three complete seconds and the current partial second.
            let elapsed = 3 + Double(now % Self.nanosPerSecond) / Double(Self.nanosPerSecond)
            return bytes / elapsed
        }
    }
}

/// Collect URLSession's response chunks without a per-byte async iterator.
/// The cap is enforced before appending each chunk, including chunked bodies.
final class BoundedHTTPResponseClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        let maximum: Int
        let validate: @Sendable (HTTPURLResponse) throws -> Void
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var task: URLSessionTask?
        private var response: HTTPURLResponse?
        private var data = Data()
        private var finished = false
        private var cancelled = false

        init(maximum: Int, validate: @escaping @Sendable (HTTPURLResponse) throws -> Void) {
            self.maximum = maximum; self.validate = validate
        }
        func begin(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) -> Bool {
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
            self.continuation = continuation; lock.unlock(); return true
        }
        func attach(_ task: URLSessionTask) {
            lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
            if cancel { task.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; lock.unlock()
            finish(.failure(CancellationError())); task?.cancel()
        }
        func accept(_ response: URLResponse) -> Bool {
            do {
                guard let response = response as? HTTPURLResponse else { throw StorageFailure.invalidResponse }
                try validate(response)
                // HEAD's Content-Length describes the object, not its empty body.
                if task?.originalRequest?.httpMethod != "HEAD", response.expectedContentLength > Int64(maximum) {
                    throw StorageFailure.invalidResponse
                }
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return false }
                self.response = response
                return true
            } catch { finish(.failure(error)); return false }
        }
        func append(_ chunk: Data) -> Bool {
            lock.lock()
            guard !finished else { lock.unlock(); return false }
            guard chunk.count <= maximum - data.count else {
                lock.unlock(); finish(.failure(StorageFailure.invalidResponse)); return false
            }
            data.append(chunk); lock.unlock(); return true
        }
        func complete(_ error: Error?) {
            if let error { finish(.failure(error)); return }
            lock.lock()
            let result: Result<(Data, HTTPURLResponse), Error> = response.map { .success((data, $0)) } ?? .failure(StorageFailure.invalidResponse)
            lock.unlock(); finish(result)
        }
        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; let continuation = continuation; self.continuation = nil
            data = Data(); lock.unlock()
            continuation?.resume(with: result)
        }
    }
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let uploadThroughput: UploadThroughput?
    private var transfers: [Int: Transfer] = [:]
    private var activeSession: URLSession?
    private var closed = false
    init(configuration: URLSessionConfiguration, uploadThroughput: UploadThroughput? = nil) {
        self.configuration = configuration
        self.uploadThroughput = uploadThroughput
        super.init()
    }
    private func makeTask(_ request: URLRequest, transfer: Transfer) -> URLSessionDataTask? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        if activeSession == nil { activeSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil) }
        // Task creation must precede close's invalidation under the same lock.
        // URLSession can raise an Objective-C exception if used after invalidation.
        let task = activeSession!.dataTask(with: request)
        transfers[task.taskIdentifier] = transfer
        return task
    }
    func close() {
        lock.lock(); closed = true; let session = activeSession; let pending = Array(transfers.values); transfers.removeAll(); lock.unlock()
        for transfer in pending { transfer.cancel() }
        session?.invalidateAndCancel()
    }
    func data(for request: URLRequest, maximum: Int,
              validate: @escaping @Sendable (HTTPURLResponse) throws -> Void) async throws -> (Data, HTTPURLResponse) {
        guard maximum >= 0 else { throw StorageFailure.invalidResponse }
        let transfer = Transfer(maximum: maximum, validate: validate)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard transfer.begin(continuation) else { return }
                guard let task = makeTask(request, transfer: transfer) else { transfer.complete(URLError(.cancelled)); return }
                transfer.attach(task)
                task.resume()
            }
        } onCancel: { transfer.cancel() }
    }
    private func transfer(_ task: URLSessionTask) -> Transfer? {
        lock.lock(); defer { lock.unlock() }; return transfers[task.taskIdentifier]
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(transfer(dataTask)?.accept(response) == true ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if transfer(dataTask)?.append(data) != true { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard task.originalRequest?.httpMethod == "PUT" else { return }
        uploadThroughput?.record(bytesSent)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let transfer = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        transfer?.complete(error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
