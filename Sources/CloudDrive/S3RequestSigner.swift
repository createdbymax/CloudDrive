import Foundation
import CryptoKit

/// Shared SigV4 encoding. Object-write scope validation stays in S3MultipartRemote.
/// A nil key signs a bucket request (LIST), never an arbitrary endpoint.
enum S3RequestSigner {
    static func encode(_ string: String) -> String { S3MultipartRemote.encode(string) }
    static func request(connection: Connection, method: String, key: String?, query: [(String, String)] = [],
                        headers: [String: String] = [:], body: Data = Data(), date: Date = Date()) throws -> URLRequest {
        guard var components = URLComponents(string: connection.endpoint), let host = components.host else { throw MultipartRemoteError.invalidResponse }
        components.percentEncodedPath = "/" + encode(connection.bucket) + (key.map { "/" + $0.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/") } ?? "")
        let encodedQuery: [(String, String)] = query.map { (encode($0.0), encode($0.1)) }
        let sortedQuery = encodedQuery.sorted { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }
        let queryString = sortedQuery.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
        components.percentEncodedQuery = queryString.isEmpty ? nil : queryString
        guard let url = components.url else { throw MultipartRemoteError.invalidResponse }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        let payload = SHA256.hash(data: body).hex
        var signed = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        signed["host"] = host + (components.port.map { ":\($0)" } ?? "")
        signed["x-amz-date"] = timestamp; signed["x-amz-content-sha256"] = payload
        let names = signed.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(signed[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [method, components.percentEncodedPath, queryString, canonicalHeaders, signedHeaders, payload].joined(separator: "\n")
        let scope = "\(day)/auto/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(SHA256.hash(data: Data(canonical.utf8)).hex)"
        func hmac(_ key: Data, _ text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))) }
        let signingKey = hmac(hmac(hmac(hmac(Data(("AWS4" + connection.secretKey).utf8), day), "auto"), "s3"), "aws4_request")
        let signature = hmac(signingKey, toSign).hex
        var request = URLRequest(url: url); request.httpMethod = method
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(connection.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        // R2 can compress JSON metadata responses, omitting Content-Length and weakening ETags.
        // Identity preserves the stored object's size/checksum; this ordinary header need not be signed.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if method != "HEAD" && method != "GET" { request.httpBody = body }
        return request
    }

}
