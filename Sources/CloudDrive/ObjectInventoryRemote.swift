import Foundation


/// Read-only S3 inventory. No mount access, payload GET, write, redirects or proxies.
final class S3InventoryRemote: NSObject, ObjectInventoryRemote, URLSessionTaskDelegate, @unchecked Sendable {
    private let connection: Connection
    private let validateEndpoint: Bool
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    init(connection: Connection, validateEndpoint: Bool = true) { self.connection = connection; self.validateEndpoint = validateEndpoint }
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    private func response(method: String, key: String?, query: [(String, String)]) async throws -> (Data, Int) {
        if validateEndpoint { try connection.validate() }
        let request = try S3RequestSigner.request(connection: connection, method: method, key: key, query: query)
        return try await withThrowingTaskGroup(of: (Data, Int).self) { group in
            group.addTask { [self] in
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw CatalogFailure.invalidInventory }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 4_194_304 else { throw CatalogFailure.invalidInventory }
                    data.append(byte)
                }
                return (data, http.statusCode)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    func list(token: String?) async throws -> InventoryPage {
        try await list(scope: connection.prefix + "/", token: token)
    }
    func list(scope: String, token: String?) async throws -> InventoryPage {
        guard scope.utf8.starts(with: (connection.prefix + "/").utf8), scope.hasSuffix("/") else { throw CatalogFailure.invalidInventory }
        var query = [("list-type", "2"), ("prefix", scope), ("max-keys", "1000"), ("encoding-type", "url")]
        if let token { query.append(("continuation-token", token)) }
        let (data, status) = try await response(method: "GET", key: nil, query: query)
        guard status == 200 else { throw CatalogFailure.http(status) }
        return try InventoryXML.parse(data, bucket: connection.bucket, prefix: connection.prefix, scope: scope)
    }
    func head(key: String) async throws -> CatalogObject? {
        guard key.utf8.starts(with: (connection.prefix + "/").utf8), key.utf8.count <= 1024,
              !key.contains("\0"), !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { throw CatalogFailure.invalidInventory }
        if validateEndpoint { try connection.validate() }
        let request = try S3RequestSigner.request(connection: connection, method: "HEAD", key: key)
        // Response headers must be retained; no object body is requested.
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard data.isEmpty, let response = response as? HTTPURLResponse else { throw CatalogFailure.invalidInventory }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw CatalogFailure.http(response.statusCode) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let size = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
              let etag = response.value(forHTTPHeaderField: "ETag"),
              let date = response.value(forHTTPHeaderField: "Last-Modified").flatMap(formatter.date(from:)) else { throw CatalogFailure.invalidInventory }
        let object = CatalogObject(key: key, size: size, modified: date, etag: etag)
        try CatalogText.validate(object, prefix: connection.prefix)
        return object
    }
    func isMissing(key: String) async throws -> Bool {
        guard key.utf8.starts(with: (connection.prefix + "/").utf8) else { throw CatalogFailure.invalidInventory }
        // Dot segments cannot be safely represented by URLSession. Preserve them as unknown.
        guard !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { throw CatalogFailure.invalidInventory }
        let (_, status) = try await response(method: "HEAD", key: key, query: [])
        if status == 404 { return true }
        guard status == 200 else { throw CatalogFailure.http(status) }
        return false
    }
}

/// Strict per-record parser: no external entities, duplicate fields or partial success.
final class InventoryXML: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var root: [String: String] = [:]
    private var current: [String: String] = [:]
    private var records: [[String: String]] = []
    private var invalid = false
    static func parse(_ data: Data, bucket: String, prefix: String, scope: String? = nil) throws -> InventoryPage {
        let scope = scope ?? prefix + "/"
        guard data.count <= 4_194_304 else { throw CatalogFailure.invalidInventory }
        let delegate = InventoryXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.path.isEmpty,
              delegate.root["Name"] == bucket, delegate.root["EncodingType"] == "url",
              delegate.root["Prefix"]?.removingPercentEncoding.map({ Data($0.utf8) }) == Data(scope.utf8),
              let truncated = delegate.root["IsTruncated"], ["true", "false"].contains(truncated) else { throw CatalogFailure.invalidInventory }
        let token = delegate.root["NextContinuationToken"]
        guard (truncated == "true" ? token?.isEmpty == false : token == nil), (token?.utf8.count ?? 0) <= 16_384 else { throw CatalogFailure.invalidInventory }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        var identities = Set<Data>()
        let objects = try delegate.records.map { record -> CatalogObject in
            guard let raw = record["Key"], let key = raw.removingPercentEncoding,
                  let size = record["Size"].flatMap(Int64.init), let date = record["LastModified"],
                  let modified = fractional.date(from: date) ?? seconds.date(from: date),
                  let etag = record["ETag"], identities.insert(Data(key.utf8)).inserted else { throw CatalogFailure.invalidInventory }
            let object = CatalogObject(key: key, size: size, modified: modified, etag: etag)
            guard key.utf8.starts(with: scope.utf8) else { throw CatalogFailure.invalidInventory }
            try CatalogText.validate(object, prefix: prefix)
            return object
        }
        return InventoryPage(objects: objects, nextToken: token)
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        path.append(name); text = ""
        if path.count == 1 && name != "ListBucketResult" { invalid = true; parser.abortParsing() }
        if path == ["ListBucketResult", "Contents"] { current = [:] }
        if path.count > 4 { invalid = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if path.count == 3 && path[1] == "Contents" {
            if current[name] != nil { invalid = true }
            current[name] = text
        } else if path == ["ListBucketResult", "Contents"] {
            records.append(current)
            if records.count > 1000 { invalid = true; parser.abortParsing() }
        } else if path.count == 2 {
            if root[name] != nil { invalid = true }
            root[name] = text
        }
        path.removeLast(); text = ""
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}
