import XCTest
@testable import CloudDrive
final class CloudCachePolicyTests: XCTestCase {
    func testOnlyObservedEffectivePolicyCanBeReportedActive() throws {
        let expected = try JSONDecoder().decode(CloudCachePolicy.CacheOptions.self, from: Data(#"{"CacheMaxAge":1000000000,"CachePollInterval":1000000000}"#.utf8))
        let previous = try JSONDecoder().decode(CloudCachePolicy.CacheOptions.self, from: Data(#"{"CacheMaxAge":3600000000000,"CachePollInterval":10000000000}"#.utf8))
        XCTAssertTrue(CloudCachePolicy.isActive(expected))
        XCTAssertFalse(CloudCachePolicy.isActive(previous))
        XCTAssertFalse(CloudCachePolicy.isActive(nil))
        XCTAssertThrowsError(try JSONDecoder().decode(CloudCachePolicy.CacheOptions.self, from: Data(#"{"CacheMaxAge":"1s","CachePollInterval":true}"#.utf8)))
    }
}
