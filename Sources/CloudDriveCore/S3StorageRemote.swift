import Foundation
import CryptoKit
import Darwin

public struct R2StorageConfiguration: Codable, Sendable {
    public let endpoint: String
    public let bucket: String
    public let prefix: String
    public let accessKey: String
    public let secretKey: String
    /// Enabled only after a transport/provider qualification proves conditional DELETE.
    public var qualifiedAtomicDelete: Bool
    public var allowLoopbackFixture: Bool
    public init(endpoint: String, bucket: String, prefix: String, accessKey: String, secretKey: String,
                qualifiedAtomicDelete: Bool = false, allowLoopbackFixture: Bool = false) {
        self.endpoint = endpoint; self.bucket = bucket; self.prefix = prefix
        self.accessKey = accessKey; self.secretKey = secretKey
        self.qualifiedAtomicDelete = qualifiedAtomicDelete; self.allowLoopbackFixture = allowLoopbackFixture
    }
    public func validate() throws {
        guard let url = URLComponents(string: endpoint), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              (url.scheme == "https" && host.hasSuffix(".r2.cloudflarestorage.com") && url.port == nil) ||
              (allowLoopbackFixture && url.scheme == "http" && ["127.0.0.1", "localhost"].contains(host)),
              bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
              prefix.range(of: "^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil,
              !prefix.isEmpty, !prefix.hasPrefix("/"), !prefix.hasSuffix("/"),
              !prefix.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !accessKey.isEmpty, !secretKey.isEmpty, !accessKey.contains("\n"), !secretKey.contains("\n") else { throw StorageFailure.invalidResponse }
    }
}

/// Bounded native S3 transport shared by the namespace owner and qualification tools.
/// It never follows redirects and never silently substitutes unconditional operations.
public final class S3StorageRemote: NSObject, StorageRemote, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: R2StorageConfiguration
    private let multipartDirectory: URL
    private let multipartBudget: MultipartPartBudget
    private let managedPartsPerFile: Int
    private let bulkTransportCount: Int
    private var qualificationProxyPort: UInt16?
    private let capabilityLock = NSLock()
    private var deleteQualified: Bool
    private struct DeleteQualification: Codable { var version = 1; var scope: String; var checkedAt: Date; var wrongValidatorRejected: Bool; var matchingValidatorDeleted: Bool }
    private let transportLock = NSLock()
    private let uploadThroughput = UploadThroughput()
    private var responseClients: [Int: BoundedHTTPResponseClient] = [:]
    private var nextBulkTransport = 0
    private var transportClosed = false
    private func transport(bulk: Bool) throws -> BoundedHTTPResponseClient {
        transportLock.lock(); defer { transportLock.unlock() }
        guard !transportClosed else { throw StorageFailure.offline }
        var lane = 0
        if bulk, bulkTransportCount > 0 {
            lane = nextBulkTransport + 1
            nextBulkTransport = (nextBulkTransport + 1) % bulkTransportCount
        }
        if let client = responseClients[lane] { return client }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 900
        config.httpMaximumConnectionsPerHost = 8
        #if DEBUG
        if let port = qualificationProxyPort {
            config.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(port)]
        }
        #endif
        let client = BoundedHTTPResponseClient(configuration: config, uploadThroughput: uploadThroughput)
        responseClients[lane] = client
        return client
    }
    public init(configuration: R2StorageConfiguration, multipartDirectory: URL, managedThroughput: Bool = false) throws {
        try configuration.validate(); self.configuration = configuration; self.multipartDirectory = multipartDirectory
        deleteQualified = configuration.qualifiedAtomicDelete
        multipartBudget = managedThroughput ? MultipartPartBudget(maximumRequests: 12, maximumBytes: 192 * 1024 * 1024) : MultipartPartBudget()
        managedPartsPerFile = managedThroughput ? 8 : 4
        bulkTransportCount = managedThroughput ? 4 : 0
        super.init()
        try FileManager.default.createDirectory(at: multipartDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(multipartDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StorageFailure.integrity }
        let proof = multipartDirectory.appendingPathComponent("conditional-delete.json")
        if FileManager.default.fileExists(atPath: proof.path) {
            let saved = try CoreFileIO.readChecked(DeleteQualification.self, at: proof, maximum: 16_384)
            let age = Date().timeIntervalSince(saved.checkedAt)
            if saved.version == 1, saved.scope == capabilityScope, saved.wrongValidatorRejected, saved.matchingValidatorDeleted, age >= 0, age < 30 * 86_400 { deleteQualified = true }
        }
    }
    #if DEBUG
    /// Only the disposable signed R2 qualification owner may use this loopback TLS tunnel.
    public convenience init(qualification configuration: R2StorageConfiguration, multipartDirectory: URL, port: UInt16,
                            managedThroughput: Bool = false) throws {
        let prefix = "clouddrive-qualification-"
        guard port > 0, configuration.prefix.hasPrefix(prefix),
              let id = UUID(uuidString: String(configuration.prefix.dropFirst(prefix.count))),
              configuration.prefix == prefix + id.uuidString.lowercased(),
              multipartDirectory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "native-" + id.uuidString
        else { throw StorageFailure.invalidResponse }
        try self.init(configuration: configuration, multipartDirectory: multipartDirectory, managedThroughput: managedThroughput)
        qualificationProxyPort = port
    }
    #endif
    /// Recent PUT body throughput, independent of publication and verification.
    public func uploadBytesPerSecond() -> Double { uploadThroughput.bytesPerSecond() }

    public func close() {
        transportLock.lock(); transportClosed = true; let clients = Array(responseClients.values); responseClients.removeAll(); transportLock.unlock()
        for client in clients { client.close() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    private func keyAllowed(_ key: String) -> Bool {
        key.utf8.count <= 1024 && key.hasPrefix(configuration.prefix + "/") && !key.contains("\0") &&
        !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
    }
    private static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func signedRequest(method: String, key: String?, query: [(String, String)] = [], headers: [String: String] = [:], body: Data = Data(), date: Date = Date()) throws -> URLRequest {
        guard key.map(keyAllowed) ?? true, var components = URLComponents(string: configuration.endpoint), let host = components.host else { throw StorageFailure.invalidResponse }
        components.percentEncodedPath = "/" + Self.encode(configuration.bucket) + (key.map { "/" + $0.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/") } ?? "")
        let encoded: [(String, String)] = query.map { (Self.encode($0.0), Self.encode($0.1)) }
        let sorted = encoded.sorted { left, right in
            if left.0 == right.0 { return left.1 < right.1 }
            return left.0 < right.0
        }
        let queryString = sorted.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
        components.percentEncodedQuery = queryString.isEmpty ? nil : queryString
        guard let url = components.url else { throw StorageFailure.invalidResponse }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date), day = String(stamp.prefix(8)), payload = Self.digest(body)
        var signed = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard signed.allSatisfy({ !$0.key.contains("\n") && !$0.value.contains("\n") && !$0.value.contains("\r") }) else { throw StorageFailure.invalidResponse }
        signed["host"] = host + (components.port.map { ":\($0)" } ?? "")
        signed["x-amz-date"] = stamp; signed["x-amz-content-sha256"] = payload
        let names = signed.keys.sorted(), scope = "\(day)/auto/s3/aws4_request"
        let canonical = [method, components.percentEncodedPath, queryString, names.map { "\($0):\(signed[$0]!)\n" }.joined(), names.joined(separator: ";"), payload].joined(separator: "\n")
        func hmac(_ key: Data, _ text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))) }
        let signingKey = hmac(hmac(hmac(hmac(Data(("AWS4" + configuration.secretKey).utf8), day), "auto"), "s3"), "aws4_request")
        let signature = hmac(signingKey, "AWS4-HMAC-SHA256\n\(stamp)\n\(scope)\n\(Self.digest(Data(canonical.utf8)))").map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: url); request.httpMethod = method
        for (key, value) in signed { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(configuration.accessKey)/\(scope), SignedHeaders=\(names.joined(separator: ";")), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if method != "GET" && method != "HEAD" { request.httpBody = body }
        return request
    }
    private func request(_ method: String, _ key: String?, query: [(String, String)] = [], headers: [String: String] = [:], body: Data = Data(), maximum: Int = 4_194_304) async throws -> (Data, HTTPURLResponse) {
        let request = try signedRequest(method: method, key: key, query: query, headers: headers, body: body)
        do {
            // Large transfers have their own connections so bulk TLS streams
            // cannot delay manifest HEADs and other small control requests.
            let bulk = body.count >= 1_048_576 || (maximum >= 1_048_576 && headers["Range"] != nil)
            return try await transport(bulk: bulk).data(for: request, maximum: maximum) { response in
                if response.statusCode == 404 { throw StorageFailure.notFound }
                if [409, 412].contains(response.statusCode) { throw StorageFailure.conflict }
                if [408, 429, 500, 502, 503, 504].contains(response.statusCode) {
                    throw ["GET", "HEAD"].contains(method) ? StorageFailure.offline : StorageFailure.unknownOutcome
                }
                guard (200..<300).contains(response.statusCode) else { throw StorageFailure.invalidResponse }
            }
        } catch let error as StorageFailure { throw error }
        catch {
            // No automatic mutation retries: the server may have committed before timeout.
            throw ["GET", "HEAD"].contains(method) ? StorageFailure.offline : StorageFailure.unknownOutcome
        }
    }
    private func object(_ key: String, response: HTTPURLResponse) throws -> StorageObject {
        guard let size = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), size >= 0,
              let validator = response.value(forHTTPHeaderField: "ETag"), !validator.isEmpty else { throw StorageFailure.invalidResponse }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let customTime = response.value(forHTTPHeaderField: "x-amz-meta-mtime").flatMap(Double.init).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        return StorageObject(key: key, size: size, validator: validator,
                             checksum: response.value(forHTTPHeaderField: "x-amz-meta-clouddrive-sha256"),
                             operationID: response.value(forHTTPHeaderField: "x-amz-meta-clouddrive-operation-id").flatMap(UUID.init(uuidString:)),
                             modifiedAt: customTime ?? response.value(forHTTPHeaderField: "Last-Modified").flatMap(formatter.date(from:)))
    }
    public func head(key: String) async throws -> StorageObject? {
        do { let (_, response) = try await request("HEAD", key); return try object(key, response: response) }
        catch StorageFailure.notFound { return nil }
    }
    public func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange {
        guard range.lowerBound >= 0, range.count > 0, range.count <= 16_777_216, !validator.isEmpty else { throw StorageFailure.invalidRange }
        let (data, response) = try await request("GET", key, headers: ["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)", "If-Match": validator], maximum: Int(range.count))
        let prefix = "bytes \(range.lowerBound)-\(range.upperBound - 1)/"
        guard response.statusCode == 206, let contentRange = response.value(forHTTPHeaderField: "Content-Range"), contentRange.hasPrefix(prefix),
              let total = Int64(contentRange.dropFirst(prefix.count)), total >= range.upperBound,
              data.count == range.count, response.value(forHTTPHeaderField: "ETag") == validator else { throw StorageFailure.invalidRange }
        return StorageRange(data: data, offset: range.lowerBound, totalSize: total, validator: validator)
    }
    public func readContentAddressed(key: String, maximum: Int, checksum: String) async throws -> Data {
        guard (0...4_194_304).contains(maximum) else { throw StorageFailure.integrity }
        do {
            let (data, response) = try await request("GET", key, maximum: maximum)
            guard response.statusCode == 200 else { throw StorageFailure.invalidResponse }
            guard Self.digest(data) == checksum else { throw StorageFailure.integrity }
            return data
        } catch StorageFailure.notFound { throw StorageFailure.integrity }
    }
    private func conditionHeaders(_ condition: StorageCondition) -> [String: String] {
        switch condition { case .unconditional: return [:]; case .absent: return ["If-None-Match": "*"]; case .matches(let tag): return ["If-Match": tag] }
    }
    private func sendPut(key: String, data: Data, condition: StorageCondition, operationID: UUID, checksum: String) async throws {
        var headers = conditionHeaders(condition)
        headers["x-amz-meta-clouddrive-operation-id"] = operationID.uuidString
        headers["x-amz-meta-clouddrive-sha256"] = checksum
        _ = try await request("PUT", key, headers: headers, body: data)
    }
    public func putContentAddressed(key: String, data: Data, operationID: UUID) async throws {
        guard data.count <= 262_144 else { throw StorageFailure.unsupported }
        let checksum = Self.digest(data)
        guard key.hasSuffix("/" + checksum) else { throw StorageFailure.integrity }
        // Immutable pages are authenticated by their names. A successful
        // conditional PUT needs no follow-up HEAD to construct a locator.
        try await sendPut(key: key, data: data, condition: .absent, operationID: operationID, checksum: checksum)
    }
    public func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject {
        guard data.count <= 16_777_216 else { throw StorageFailure.unsupported }
        let checksum = Self.digest(data)
        try await sendPut(key: key, data: data, condition: condition, operationID: operationID, checksum: checksum)
        guard let value = try await head(key: key), value.operationID == operationID, value.size == data.count, value.checksum == checksum else { throw StorageFailure.integrity }
        return value
    }
    public func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) async throws -> StorageObject {
        guard keyAllowed(source), keyAllowed(destination), !sourceValidator.isEmpty, source != destination else { throw StorageFailure.invalidResponse }
        guard let original = try await head(key: source), original.validator == sourceValidator else { throw StorageFailure.conflict }
        // An existing unproven destination is never overwritten. A previous known copy
        // can be reconciled using operation metadata after an uncertain reply.
        if let existing = try await head(key: destination) {
            guard existing.operationID == operationID, existing.size == original.size,
                  original.checksum == nil || existing.checksum == original.checksum else { throw StorageFailure.conflict }; return existing
        }
        // R2 multipart-copy does not provide the source-validator and destination
        // commit fences required by compatible relocation. Fail before mutation
        // rather than timing out or substituting an unsafe multipart operation.
        guard original.size <= 5 * 1024 * 1024 * 1024 else { throw StorageFailure.unsupported }
        let data = try await copyObject(original: original, destination: destination, sourceValidator: sourceValidator, operationID: operationID)
        let xml = try StorageXML(data)
        guard xml.root == "CopyObjectResult", xml.values["ETag"] != nil,
              let copied = try await head(key: destination), copied.size == original.size,
              copied.operationID == operationID, original.checksum == nil || copied.checksum == original.checksum else { throw StorageFailure.integrity }
        return copied
    }
    private func copyObject(original: StorageObject, destination: String, sourceValidator: String, operationID: UUID) async throws -> Data {
        var headers = ["x-amz-copy-source": "/" + Self.encode(configuration.bucket) + "/" + original.key.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/"),
                       "x-amz-copy-source-if-match": sourceValidator, "cf-copy-destination-if-none-match": "*",
                       "x-amz-metadata-directive": "MERGE", "x-amz-meta-clouddrive-operation-id": operationID.uuidString]
        if let checksum = original.checksum { headers["x-amz-meta-clouddrive-sha256"] = checksum }
        let (data, _) = try await request("PUT", destination, headers: headers)
        return data
    }
    #if DEBUG
    /// Test the actual provider conditions below the normal HEAD fast paths.
    /// Both negative probes address only new objects under a generated UUID.
    public func qualifyMoveCopyConditions() async throws {
        let base = configuration.prefix + "/.clouddrive/v1/qualification/" + UUID().uuidString
        let a = try await put(key: base + "/a", data: Data("copy source".utf8), condition: .absent, operationID: UUID())
        let b = try await put(key: base + "/b", data: Data("destination sentinel".utf8), condition: .absent, operationID: UUID())
        do {
            _ = try await copyObject(original: a, destination: b.key, sourceValidator: a.validator, operationID: UUID())
            throw StorageFailure.unsupported
        } catch StorageFailure.conflict {}
        guard let after = try await head(key: b.key), after.validator == b.validator, after.operationID == b.operationID,
              after.checksum == b.checksum, after.size == b.size else { throw StorageFailure.integrity }
        let missing = base + "/negative"
        do {
            _ = try await copyObject(original: a, destination: missing, sourceValidator: "\"wrong-" + UUID().uuidString + "\"", operationID: UUID())
            throw StorageFailure.unsupported
        } catch StorageFailure.conflict {}
        guard try await head(key: missing) == nil else { throw StorageFailure.integrity }
    }
    #endif
    public func delete(key: String, validator: String) async throws {
        guard capabilityLock.withLock({ deleteQualified }), !validator.isEmpty else { throw StorageFailure.unsupported }
        _ = try await request("DELETE", key, headers: ["If-Match": validator])
    }
    /// R2 does not honor conditional deletes. This private UUID key belongs to a
    /// single immutable write and is independently read and hashed before removal.
    public func removeWritebackObject(_ object: StorageObject, id: UUID, checksum: String) async throws {
        let expected = configuration.prefix + "/.clouddrive/v1/writeback/" + id.uuidString + "/" + checksum
        guard object.key == expected, checksum.utf8.count == 64, object.operationID == id,
              (1...16_777_216).contains(object.size) else { throw StorageFailure.integrity }
        guard let live = try await head(key: expected) else { return }
        guard live.operationID == id, live.validator == object.validator, live.size == object.size else { throw StorageFailure.conflict }
        _ = try await request("DELETE", expected)
    }
    private var capabilityScope: String { CoreFileIO.hash(Data((configuration.endpoint + "\0" + configuration.bucket + "\0" + configuration.prefix).utf8)) }
    /// Qualification touches only a new generated object in this connection's
    /// reserved namespace. This is observed transport support, not writer fencing;
    /// concurrent external writers remain unsupported.
    public func qualifyConditionalDelete() async throws {
        if capabilityLock.withLock({ deleteQualified }) { return }
        let id = UUID(), key = configuration.prefix + "/.clouddrive/v1/qualification/" + UUID().uuidString
        let data = Data("CloudDrive synthetic conditional-operation qualification".utf8)
        let created = try await put(key: key, data: data, condition: .absent, operationID: id)
        do {
            _ = try await request("DELETE", key, headers: ["If-Match": "\"wrong-" + UUID().uuidString + "\""])
            throw StorageFailure.unsupported
        } catch StorageFailure.conflict { /* Required negative precondition test. */ }
        guard let unchanged = try await head(key: key), unchanged.operationID == id,
              unchanged.validator == created.validator, unchanged.size == created.size, unchanged.checksum == created.checksum else { throw StorageFailure.unsupported }
        _ = try await request("DELETE", key, headers: ["If-Match": created.validator])
        guard try await head(key: key) == nil else { throw StorageFailure.unsupported }
        let proof = DeleteQualification(scope: capabilityScope, checkedAt: Date(), wrongValidatorRejected: true, matchingValidatorDeleted: true)
        try CoreFileIO.atomicChecked(proof, at: multipartDirectory.appendingPathComponent("conditional-delete.json"))
        capabilityLock.withLock { deleteQualified = true }
    }
    public func setModifiedAt(key: String, validator: String, date: Date, operationID: UUID) async throws -> StorageObject {
        guard keyAllowed(key), date.timeIntervalSince1970.isFinite, let original = try await head(key: key) else { throw StorageFailure.notFound }
        if original.operationID == operationID, original.modifiedAt == date { return original }
        guard original.validator == validator else { throw StorageFailure.conflict }
        guard original.size <= 5 * 1024 * 1024 * 1024 else { throw StorageFailure.unsupported }
        let source = "/" + Self.encode(configuration.bucket) + "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/")
        let headers = ["x-amz-copy-source": source, "x-amz-copy-source-if-match": validator,
                       "cf-copy-destination-if-match": validator, "x-amz-metadata-directive": "MERGE",
                       "x-amz-meta-mtime": String(format: "%.9f", date.timeIntervalSince1970),
                       "x-amz-meta-clouddrive-operation-id": operationID.uuidString]
        let (data, _) = try await request("PUT", key, headers: headers)
        guard try StorageXML(data).root == "CopyObjectResult", let changed = try await head(key: key), changed.size == original.size,
              changed.operationID == operationID, original.checksum == nil || changed.checksum == original.checksum,
              let observed = changed.modifiedAt, abs(observed.timeIntervalSince(date)) < 0.000_001 else { throw StorageFailure.integrity }
        return changed
    }
    public func list(prefix: String, cursor: String?, limit: Int) async throws -> StoragePage {
        guard keyAllowed(prefix), (1...1000).contains(limit) else { throw StorageFailure.invalidResponse }
        var query = [("list-type", "2"), ("prefix", prefix), ("max-keys", String(limit)), ("encoding-type", "url")]
        if let cursor { guard cursor.utf8.count <= 16_384 else { throw StorageFailure.invalidResponse }; query.append(("continuation-token", cursor)) }
        let (data, _) = try await request("GET", nil, query: query)
        let xml = try StorageXML(data)
        guard xml.root == "ListBucketResult", xml.values["Name"] == configuration.bucket,
              xml.values["EncodingType"] == "url", xml.values["Prefix"]?.removingPercentEncoding == prefix else { throw StorageFailure.invalidResponse }
        let objects = try xml.records.map { row -> StorageObject in
            guard let key = row["Key"]?.removingPercentEncoding, keyAllowed(key), key.hasPrefix(prefix),
                  let size = row["Size"].flatMap(Int64.init), size >= 0, let tag = row["ETag"] else { throw StorageFailure.invalidResponse }
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let seconds = ISO8601DateFormatter()
            return StorageObject(key: key, size: size, validator: tag, modifiedAt: row["LastModified"].flatMap { fractional.date(from: $0) ?? seconds.date(from: $0) })
        }
        let truncated = xml.values["IsTruncated"]
        guard ["true", "false"].contains(truncated), truncated != "true" || xml.values["NextContinuationToken"]?.isEmpty == false else { throw StorageFailure.invalidResponse }
        return StoragePage(objects: objects, nextCursor: truncated == "true" ? xml.values["NextContinuationToken"] : nil)
    }

    private struct MultipartState: Codable {
        var key: String; var size: Int64; var operationID: UUID; var uploadID: String; var temporaryKey: String
        var parts: [Int: String]; var completed: Bool
    }
    private func remoteParts(_ state: MultipartState) async throws -> [Int: (etag: String, size: Int64)] {
        var parts: [Int: (etag: String, size: Int64)] = [:], marker: String?
        var seen: Set<String> = []
        while true {
            var query = [("uploadId", state.uploadID), ("max-parts", "1000")]
            if let marker { query.append(("part-number-marker", marker)) }
            let (data, _) = try await request("GET", state.temporaryKey, query: query)
            let xml = try StorageXML(data)
            guard xml.root == "ListPartsResult", xml.values["Bucket"] == configuration.bucket,
                  xml.values["Key"]?.removingPercentEncoding == state.temporaryKey || xml.values["Key"] == state.temporaryKey,
                  xml.values["UploadId"] == state.uploadID else { throw StorageFailure.invalidResponse }
            for row in xml.parts {
                guard let number = row["PartNumber"].flatMap(Int.init), (1...9999).contains(number),
                      let tag = row["ETag"], !tag.isEmpty, let size = row["Size"].flatMap(Int64.init), size > 0,
                      parts[number] == nil else { throw StorageFailure.invalidResponse }
                parts[number] = (tag, size)
            }
            guard parts.count <= 9999 else { throw StorageFailure.invalidResponse }
            if xml.values["IsTruncated"] == "false" { return parts }
            guard xml.values["IsTruncated"] == "true", let next = xml.values["NextPartNumberMarker"],
                  let number = Int(next), number > (marker.flatMap(Int.init) ?? 0), number <= 9999,
                  seen.insert(next).inserted else { throw StorageFailure.invalidResponse }
            marker = next
        }
    }
    private func save(_ state: MultipartState, at url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let fd = Darwin.open(temp.path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StorageFailure.integrity }
        defer { Darwin.close(fd); unlink(temp.path) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try file.write(contentsOf: JSONEncoder().encode(state)); try file.synchronize()
        guard Darwin.rename(temp.path, url.path) == 0 else { throw StorageFailure.integrity }
        let directory = Darwin.open(multipartDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw StorageFailure.integrity }; defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw StorageFailure.integrity }
    }
    public func upload(key: String, size: Int64, condition: StorageCondition, operationID: UUID,
                       reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        try await uploadImpl(key: key, size: size, condition: condition, operationID: operationID, immutableContent: false, reader: reader)
    }
    public func uploadContent(keyHint: String, size: Int64, operationID: UUID,
                              reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        guard keyHint.hasPrefix(configuration.prefix + "/.clouddrive/v1/content/") else { throw StorageFailure.invalidResponse }
        return try await uploadImpl(key: keyHint, size: size, condition: .absent, operationID: operationID, immutableContent: true, reader: reader)
    }
    private func uploadImpl(key: String, size: Int64, condition: StorageCondition, operationID: UUID, immutableContent: Bool,
                            reader: @escaping @Sendable (Range<Int64>) async throws -> Data) async throws -> StorageObject {
        guard keyAllowed(key), size >= 0, size <= 67_108_864 * 9999 else { throw StorageFailure.invalidResponse }
        // Ordinary-key publication still uses conditional CopyObject. Refuse an
        // unsupported size before reading or uploading any source bytes; otherwise
        // a large accepted upload can strand gigabytes at an unpublishable staging
        // key. Managed immutable content does not need this final copy.
        guard immutableContent || size <= 5 * 1024 * 1024 * 1024 else { throw StorageFailure.unsupported }
        if size <= 8_388_608 {
            let data = try await reader(0..<size); guard data.count == size else { throw StorageFailure.integrity }
            return try await put(key: key, data: data, condition: condition, operationID: operationID)
        }
        // Multipart completion publishes only a unique immutable temporary object.
        // A conditional CopyObject controls publication to the final key.
        let url = multipartDirectory.appendingPathComponent(operationID.uuidString + ".json")
        let partSize = max(16_777_216, ((size + 9_998) / 9_999 + 1_048_575) / 1_048_576 * 1_048_576)
        guard partSize <= 67_108_864 else { throw StorageFailure.unsupported }
        let count = Int((size + partSize - 1) / partSize)
        var state: MultipartState
        if FileManager.default.fileExists(atPath: url.path) {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw StorageFailure.integrity }
            defer { Darwin.close(fd) }; var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_size <= 2_097_152 else { throw StorageFailure.integrity }
            state = try JSONDecoder().decode(MultipartState.self, from: FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data())
            guard state.key == key, state.size == size, state.operationID == operationID, keyAllowed(state.temporaryKey),
                  !immutableContent || state.temporaryKey.hasPrefix(configuration.prefix + "/.clouddrive/v1/content/")
            else { throw StorageFailure.integrity }
        } else {
            let temporary = configuration.prefix + "/.clouddrive/v1/" + (immutableContent ? "content/" : "staging/") + operationID.uuidString + (immutableContent ? "-" + UUID().uuidString : "")
            let (data, _) = try await request("POST", temporary, query: [("uploads", "")], headers: ["x-amz-meta-clouddrive-operation-id": operationID.uuidString])
            let xml = try StorageXML(data); guard let id = xml.values["UploadId"], id.utf8.count <= 16_384 else { throw StorageFailure.invalidResponse }
            state = MultipartState(key: key, size: size, operationID: operationID, uploadID: id, temporaryKey: temporary, parts: [:], completed: false)
            try save(state, at: url)
        }
        if !state.completed {
            if let existing = try await head(key: state.temporaryKey) {
                guard existing.size == size, existing.operationID == operationID else { throw StorageFailure.conflict }
                state.completed = true; try save(state, at: url)
            } else {
                do {
                    let remote = try await remoteParts(state)
                    state.parts = state.parts.filter { number, tag in
                        guard number >= 1 && number <= count else { return false }
                        let expected = min(partSize, size - Int64(number - 1) * partSize)
                        return remote[number]?.etag == tag && remote[number]?.size == expected
                    }
                    try save(state, at: url)
                } catch StorageFailure.notFound {
                    // Never reuse an uncertain completion's key for a fresh upload.
                    // An older in-flight completion can only create an orphan, not
                    // overwrite this attempt's immutable bytes or final destination.
                    if let existing = try await head(key: state.temporaryKey), existing.size == size, existing.operationID == operationID {
                        state.completed = true
                    } else {
                        state.temporaryKey = configuration.prefix + "/.clouddrive/v1/" + (immutableContent ? "content/" : "staging/") + operationID.uuidString + "-" + UUID().uuidString
                        state.uploadID = ""; state.parts = [:]
                        try save(state, at: url)
                        let (data, _) = try await request("POST", state.temporaryKey, query: [("uploads", "")], headers: ["x-amz-meta-clouddrive-operation-id": operationID.uuidString])
                        guard let id = try StorageXML(data).values["UploadId"], !id.isEmpty else { throw StorageFailure.invalidResponse }
                        state.uploadID = id
                    }
                    try save(state, at: url)
                }
            }
            if !state.completed {
                let missing = (1...count).filter { state.parts[$0] == nil }
                let temporaryKey = state.temporaryKey, uploadID = state.uploadID
                try await withThrowingTaskGroup(of: (Int, Result<String, Error>).self) { group in
                    var next = 0
                    var firstFailure: Error?
                    func start(_ number: Int) {
                        group.addTask { [self] in
                            do {
                                let offset = Int64(number - 1) * partSize, range = offset..<min(size, offset + partSize)
                                let part = try await multipartBudget.withLease(bytes: Int64(range.count)) { [self] in
                                    try Task.checkCancellation()
                                    let query = [("partNumber", String(number)), ("uploadId", uploadID)]
                                    let data = try await reader(range); guard data.count == range.count else { throw StorageFailure.integrity }
                                    let md5 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()
                                    // A part PUT with the same upload ID and number is idempotent, so a
                                    // transient failure is retried here instead of failing the whole file.
                                    var response: HTTPURLResponse?
                                    for attempt in 0..<4 {
                                        do {
                                            response = try await request("PUT", temporaryKey, query: query, headers: ["Content-MD5": md5], body: data).1
                                            break
                                        } catch let failure as StorageFailure where attempt < 3 && (failure == .offline || failure == .unknownOutcome) {
                                            try Task.checkCancellation()
                                            try await Task.sleep(for: .seconds(0.5 * Double(1 << attempt) + Double.random(in: 0...0.2)))
                                        }
                                    }
                                    guard let response else { throw StorageFailure.unknownOutcome }
                                    guard let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else { throw StorageFailure.invalidResponse }
                                    return etag
                                }
                                return (number, .success(part))
                            } catch {
                                return (number, .failure(error))
                            }
                        }
                    }
                    let parallelism = immutableContent ? managedPartsPerFile : 4
                    for _ in 0..<min(parallelism, missing.count) { start(missing[next]); next += 1 }
                    // Only this coordinator mutates the durable receipt. A failed
                    // part stops refill, while admitted parts settle and successful
                    // replies remain durable for replay. Cancellation cancels/drains
                    // children; uncertain PUTs keep their existing upload identity.
                    for try await (number, result) in group {
                        switch result {
                        case .success(let part):
                            state.parts[number] = part
                            try save(state, at: url)
                        case .failure(let error): if firstFailure == nil { firstFailure = error }
                        }
                        if Task.isCancelled { group.cancelAll(); firstFailure = CancellationError() }
                        if firstFailure == nil, next < missing.count { start(missing[next]); next += 1 }
                    }
                    if let firstFailure { throw firstFailure }
                }
            }
            if state.completed { /* Already reconciled a completed immutable temporary. */ }
            else if let existing = try await head(key: state.temporaryKey), existing.size == size, existing.operationID == operationID {
                state.completed = true; try save(state, at: url)
            } else {
                let body = "<CompleteMultipartUpload>" + state.parts.keys.sorted().map { "<Part><PartNumber>\($0)</PartNumber><ETag>\(StorageXML.escape(state.parts[$0]!))</ETag></Part>" }.joined() + "</CompleteMultipartUpload>"
                let (data, _) = try await request("POST", state.temporaryKey, query: [("uploadId", state.uploadID)], body: Data(body.utf8))
                let xml = try StorageXML(data); guard xml.root == "CompleteMultipartUploadResult" else { throw StorageFailure.invalidResponse }
                state.completed = true; try save(state, at: url)
            }
        }
        guard let temporary = try await head(key: state.temporaryKey), temporary.size == size, temporary.operationID == operationID else { throw StorageFailure.integrity }
        // Managed names live in the namespace manifest. The verified immutable
        // object can be referenced directly; large files need no second CopyObject.
        if immutableContent { return temporary }
        if let existing = try await head(key: key), existing.operationID == operationID, existing.size == size { return existing }
        var headers = ["x-amz-copy-source": "/" + configuration.bucket + "/" + state.temporaryKey.split(separator: "/").map { Self.encode(String($0)) }.joined(separator: "/"), "x-amz-copy-source-if-match": temporary.validator]
        switch condition {
        case .absent: headers["cf-copy-destination-if-none-match"] = "*"
        case .matches(let tag): headers["cf-copy-destination-if-match"] = tag
        case .unconditional: break
        }
        let (data, _) = try await request("PUT", key, headers: headers)
        guard try StorageXML(data).root == "CopyObjectResult", let final = try await head(key: key), final.operationID == operationID, final.size == size else { throw StorageFailure.integrity }
        // Keep multipart receipts and immutable temporary content until explicit GC.
        return final
    }

}

private final class StorageXML: NSObject, XMLParserDelegate {
    var root = "", values: [String: String] = [:], records: [[String: String]] = [], parts: [[String: String]] = []
    private var stack: [String] = [], text = "", row: [String: String] = [:], invalid = false
    init(_ data: Data) throws {
        super.init(); guard data.count <= 4_194_304 else { throw StorageFailure.invalidResponse }
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse(), !invalid, stack.isEmpty, root != "Error" else { throw StorageFailure.invalidResponse }
    }
    static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        stack.append(name); text = ""; if stack.count == 1 { root = name }; if stack.count == 2 && ["Contents", "Part"].contains(name) { row = [:] }
        if stack.count > 6 { invalid = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count == 3 && ["Contents", "Part"].contains(stack[1]) { if row[name] != nil { invalid = true }; row[name] = text }
        if stack.count == 2 {
            if name == "Contents" { records.append(row) }
            else if name == "Part" { parts.append(row) }
            else { if values[name] != nil { invalid = true }; values[name] = text }
        }
        _ = stack.popLast(); text = ""
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { invalid = true; parser.abortParsing(); return nil }
}
