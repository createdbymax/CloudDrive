import Foundation
import CryptoKit
import UniformTypeIdentifiers

struct RemoteUploadPart: Sendable, Equatable { let number: Int; let etag: String; let size: Int64 }
struct RemoteUploadObject: Sendable { let size: Int64; let etag: String; let jobID: String? }

enum MultipartRemoteError: Error, LocalizedError, Equatable {
    case http(Int), expired, invalidResponse, checksumMismatch
    var errorDescription: String? {
        switch self {
        case .http(let status): return "R2 returned HTTP \(status). Check the connection and permissions, then retry. Confirmed parts are retained."
        case .expired: return "The multipart upload has expired or was removed on R2. Use Restart expired upload to start a new session."
        case .invalidResponse: return "R2 returned an unexpected response. The upload needs reconciliation before it can continue."
        case .checksumMismatch: return "The remote checksum does not match the source. Upload records and originals were preserved."
        }
    }
}

protocol MultipartRemote: Sendable {
    func head(key: String) async throws -> RemoteUploadObject?
    func create(key: String, jobID: UUID) async throws -> String
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart]
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws
    func putEmpty(key: String, jobID: UUID) async throws
    func abort(key: String, uploadID: String) async throws
}

protocol SingleObjectRemote: MultipartRemote {
    func putObject(key: String, jobID: UUID, data: Data, md5: String) async throws
}

/// Path-style SigV4 requests. Ephemeral foreground sessions never spool upload payloads to disk.
final class S3MultipartRemote: NSObject, SingleObjectRemote, URLSessionTaskDelegate, @unchecked Sendable {
    private let connection: Connection
    private var session: URLSession!
    private let throughputLock = NSLock()
    private var sentBodyBytes: Int64 = 0
    private var inFlight: [Int: Int64] = [:]
    init(connection: Connection, configuration: URLSessionConfiguration? = nil) {
        self.connection = connection
        super.init()
        let config = configuration ?? .ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 16
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }

    /// Transport telemetry only: counts PUT payload bytes sent, including retransmitted attempts.
    /// This is not a durable-progress counter and never substitutes for part acknowledgements.
    func sentPayloadBytes() -> Int64 {
        throughputLock.lock(); defer { throughputLock.unlock() }
        return sentBodyBytes
    }

    /// Bytes of part/object bodies currently on the wire, for smooth progress between part acknowledgements.
    /// Never durable: a part only counts as done once R2 confirms it.
    func inFlightPayloadBytes() -> Int64 {
        throughputLock.lock(); defer { throughputLock.unlock() }
        return inFlight.values.reduce(0, +)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        throughputLock.lock(); inFlight.removeValue(forKey: task.taskIdentifier); throughputLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard bytesSent > 0, task.originalRequest?.httpMethod == "PUT" else { return }
        throughputLock.lock()
        inFlight[task.taskIdentifier] = totalBytesSent
        let result = sentBodyBytes.addingReportingOverflow(bytesSent)
        sentBodyBytes = result.overflow ? Int64.max : result.partialValue
        throughputLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))!
    }

    static func signedRequest(connection: Connection, method: String, key: String, query: [(String, String)] = [],
                              headers: [String: String] = [:], body: Data = Data(), date: Date = Date()) throws -> URLRequest {
        guard key.hasPrefix(connection.prefix + "/"), key.utf8.count <= 1024,
              !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw DirectUploadFailure.message("The upload key is outside this connection's configured prefix.")
        }
        return try S3RequestSigner.request(connection: connection, method: method, key: key, query: query,
                                           headers: headers, body: body, date: date)
    }

    private func request(_ method: String, key: String, query: [(String, String)] = [], headers: [String: String] = [:],
                         body: Data = Data(), allowNotFound: Bool = false, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<5 {
            try Task.checkCancellation()
            do {
                let request = try Self.signedRequest(connection: connection, method: method, key: key, query: query, headers: headers, body: body)
                // A bytes response provides a hard response bound, including XML error bodies.
                let (stream, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw MultipartRemoteError.invalidResponse }
                var data = Data()
                for try await byte in stream {
                    guard data.count < 2_097_152 else { throw MultipartRemoteError.invalidResponse }
                    data.append(byte)
                }
                if response.statusCode == 404 && allowNotFound { return (data, response) }
                if response.statusCode == 404 { throw MultipartRemoteError.expired }
                guard (200..<300).contains(response.statusCode) else { throw MultipartRemoteError.http(response.statusCode) }
                if method != "HEAD", !data.isEmpty {
                    let xml = try S3XML(data)
                    if xml.root == "Error" {
                        if xml.values["Code"] == "NoSuchUpload" { throw MultipartRemoteError.expired }
                        throw MultipartRemoteError.invalidResponse
                    }
                }
                return (data, response)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let transient: Bool
                if case MultipartRemoteError.http(let status) = error { transient = status == 408 || status == 429 || status >= 500 }
                else { transient = error is URLError }
                guard retry, transient, attempt < 4 else { throw error }
                try await Task.sleep(for: .seconds(Double(1 << attempt) + Double.random(in: 0...0.3)))
            }
        }
        throw MultipartRemoteError.invalidResponse
    }

    func head(key: String) async throws -> RemoteUploadObject? {
        let (_, response) = try await request("HEAD", key: key, allowNotFound: true)
        if response.statusCode == 404 { return nil }
        guard let size = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), size >= 0,
              let etag = response.value(forHTTPHeaderField: "ETag") else { throw MultipartRemoteError.invalidResponse }
        return RemoteUploadObject(size: size, etag: Self.etag(etag), jobID: response.value(forHTTPHeaderField: "x-amz-meta-clouddrive-upload-id"))
    }
    func create(key: String, jobID: UUID) async throws -> String {
        // Retrying initiation after a lost response can create untracked sessions; parts are never sent until ID is durable.
        let mime = UTType(filenameExtension: URL(fileURLWithPath: key).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let (data, _) = try await request("POST", key: key, query: [("uploads", "")], headers: ["x-amz-meta-clouddrive-upload-id": jobID.uuidString, "Content-Type": mime], retry: false)
        let xml = try S3XML(data)
        guard xml.root == "InitiateMultipartUploadResult", let id = xml.values["UploadId"], !id.isEmpty, id.utf8.count <= 4096 else { throw MultipartRemoteError.invalidResponse }
        return id
    }
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart] {
        var parts: [RemoteUploadPart] = [], marker = "0"
        for _ in 0..<11 {
            let (data, _) = try await request("GET", key: key, query: [("uploadId", uploadID), ("part-number-marker", marker), ("max-parts", "1000")])
            let xml = try S3XML(data)
            guard xml.root == "ListPartsResult" else { throw MultipartRemoteError.invalidResponse }
            parts.append(contentsOf: xml.parts)
            guard parts.count <= 10_000, Set(parts.map(\.number)).count == parts.count else { throw MultipartRemoteError.invalidResponse }
            if xml.values["IsTruncated"] == "false" { return parts }
            guard xml.values["IsTruncated"] == "true", let next = xml.values["NextPartNumberMarker"], let n = Int(next), n > (Int(marker) ?? -1) else { throw MultipartRemoteError.invalidResponse }
            marker = next
        }
        throw MultipartRemoteError.invalidResponse
    }
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String {
        guard let digest = Data(hex: md5), digest.count == 16 else { throw MultipartRemoteError.checksumMismatch }
        let (_, response) = try await request("PUT", key: key, query: [("partNumber", "\(number)"), ("uploadId", uploadID)],
                                              headers: ["Content-MD5": digest.base64EncodedString()], body: data)
        guard let tag = response.value(forHTTPHeaderField: "ETag"), Self.etag(tag) == md5 else { throw MultipartRemoteError.checksumMismatch }
        return Self.etag(tag)
    }
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws {
        let xml = "<CompleteMultipartUpload>" + parts.sorted { $0.number < $1.number }.map {
            "<Part><PartNumber>\($0.number)</PartNumber><ETag>&quot;\($0.etag)&quot;</ETag></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        let (data, _) = try await request("POST", key: key, query: [("uploadId", uploadID)], headers: ["Content-Type": "application/xml"], body: Data(xml.utf8), retry: false)
        let result = try S3XML(data)
        guard result.root == "CompleteMultipartUploadResult", result.values["ETag"] != nil else { throw MultipartRemoteError.invalidResponse }
    }
    func putEmpty(key: String, jobID: UUID) async throws {
        _ = try await request("PUT", key: key, headers: ["x-amz-meta-clouddrive-upload-id": jobID.uuidString, "If-None-Match": "*"], retry: false)
    }
    func putObject(key: String, jobID: UUID, data: Data, md5: String) async throws {
        guard !data.isEmpty, data.count <= 8 * 1_048_576, let digest = Data(hex: md5), digest.count == 16 else {
            throw MultipartRemoteError.checksumMismatch
        }
        let mime = UTType(filenameExtension: URL(fileURLWithPath: key).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let (_, response) = try await request("PUT", key: key, headers: [
            "x-amz-meta-clouddrive-upload-id": jobID.uuidString, "If-None-Match": "*",
            "Content-MD5": digest.base64EncodedString(), "Content-Type": mime
        ], body: data, retry: false)
        guard let tag = response.value(forHTTPHeaderField: "ETag"), Self.etag(tag) == md5 else {
            throw MultipartRemoteError.checksumMismatch
        }
    }
    func abort(key: String, uploadID: String) async throws {
        _ = try await request("DELETE", key: key, query: [("uploadId", uploadID)], allowNotFound: true)
    }
    static func etag(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n")).lowercased() }
}

/// Bounded XML parser. External entities and DTDs are prohibited; errors are never shown verbatim.
final class S3XML: NSObject, XMLParserDelegate {
    private(set) var root = ""
    private(set) var values: [String: String] = [:]
    private(set) var parts: [RemoteUploadPart] = []
    private var stack: [String] = []
    private var text = ""
    private var part: [String: String]?
    private var invalid = false
    init(_ data: Data) throws {
        super.init()
        guard data.count <= 2_097_152, !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw MultipartRemoteError.invalidResponse }
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse(), !invalid, !root.isEmpty else { throw MultipartRemoteError.invalidResponse }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if root.isEmpty { root = name }
        stack.append(name); text = ""
        if stack.count > 16 { invalid = true; parser.abortParsing() }
        if name == "Part" { part = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "Part" {
            if let p = part, let number = p["PartNumber"].flatMap(Int.init), number > 0, number <= 10_000,
               let etag = p["ETag"], let size = p["Size"].flatMap(Int64.init), size >= 0 {
                parts.append(.init(number: number, etag: S3MultipartRemote.etag(etag), size: size))
            } else { invalid = true }
            part = nil
        } else if part != nil { part?[name] = value }
        else { values[name] = value }
        _ = stack.popLast(); text = ""
    }
}
