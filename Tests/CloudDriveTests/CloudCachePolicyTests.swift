import XCTest
@testable import CloudDrive
final class CloudCachePolicyTests: XCTestCase {
    func testSpillWindowTracksAvailableSpaceAndStaysChunkAligned() {
        XCTAssertEqual(CloudCachePolicy.spillWindowMiB(availableBytes: 0), 8)
        XCTAssertEqual(CloudCachePolicy.spillWindowMiB(availableBytes: 160 * 1_048_576), 20)
        XCTAssertEqual(CloudCachePolicy.spillWindowMiB(availableBytes: .max), 256)
    }
    func testWritebackMigrationPreservesCacheAndRejectsTwoIndependentTrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("Cache/test-destination")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("dirty cache".utf8)
        try bytes.write(to: original.appendingPathComponent("payload"))
        let target = try CloudCachePolicy.prepareWritebackCache(legacy: original)
        XCTAssertNotEqual(target.path, original.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("payload")), bytes)
        XCTAssertEqual(try CloudCachePolicy.prepareWritebackCache(legacy: original), target)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try CloudCachePolicy.prepareWritebackCache(legacy: original))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("payload")), bytes)
    }
    func testOnlyObservedEffectivePolicyCanBeReportedActive() throws {
        let expected = try JSONDecoder().decode(CloudCachePolicy.CacheOptions.self, from: Data(#"{"CacheMaxAge":1000000000,"CachePollInterval":1000000000}"#.utf8))
        let previous = try JSONDecoder().decode(CloudCachePolicy.CacheOptions.self, from: Data(#"{"CacheMaxAge":3600000000000,"CachePollInterval":10000000000}"#.utf8))
        XCTAssertTrue(CloudCachePolicy.isActive(expected))
        XCTAssertFalse(CloudCachePolicy.isActive(previous))
        XCTAssertFalse(CloudCachePolicy.isActive(nil))
        XCTAssertThrowsError(try JSONDecoder().decode(CloudCachePolicy.CacheOptions.self, from: Data(#"{"CacheMaxAge":"1s","CachePollInterval":true}"#.utf8)))
    }
}
