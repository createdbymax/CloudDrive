import XCTest
@testable import CloudDrive
final class ConnectionTests: XCTestCase {
    func testPrefixAndEndpointConfinement() throws {
        var c = Connection(endpoint: "https://example.r2.cloudflarestorage.com", bucket: "my-bucket", prefix: "disposable/drive", accessKey: "fixture", secretKey: "fixture")
        XCTAssertNoThrow(try c.validate())
        for prefix in ["", "/", "../data", "test/../other", "test//other", "a:b", "data\nsecret"] {
            c.prefix = prefix; XCTAssertThrowsError(try c.validate(), prefix)
        }
        c.prefix = "drive"
        for endpoint in ["http://example.r2.cloudflarestorage.com", "https://example.com", "https://user:pass@example.r2.cloudflarestorage.com", "https://example.r2.cloudflarestorage.com/path", "https://example.r2.cloudflarestorage.com?token=secret"] {
            c.endpoint = endpoint; XCTAssertThrowsError(try c.validate(), endpoint)
        }
    }
    func testCacheIdentityChangesWithDestination() {
        var c = Connection(); let first = c.identity
        c.prefix = "other"; XCTAssertNotEqual(first, c.identity)
    }
}
