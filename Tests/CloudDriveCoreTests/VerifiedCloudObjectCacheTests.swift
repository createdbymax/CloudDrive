import Foundation
import XCTest
@testable import CloudDriveCore

private actor CacheFixtureRemote: StorageRemote {
    var reads = 0
    let data = Data(repeating: 42, count: 4096)
    func count() -> Int { reads }
    func read(key: String, range: Range<Int64>, validator: String) async throws -> StorageRange {
        reads += 1
        try await Task.sleep(nanoseconds: 10_000_000)
        return StorageRange(data: data, offset: 0, totalSize: Int64(data.count), validator: validator)
    }
    func head(key: String) throws -> StorageObject? { throw StorageFailure.unsupported }
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) throws -> StorageObject { throw StorageFailure.unsupported }
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) throws -> StorageObject { throw StorageFailure.unsupported }
    func delete(key: String, validator: String) throws { throw StorageFailure.unsupported }
    func list(prefix: String, cursor: String?, limit: Int) throws -> StoragePage { throw StorageFailure.unsupported }
}

final class VerifiedCloudObjectCacheTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("verified-cache-test-" + UUID().uuidString) }
    private func cache(_ dir: URL, limit: Int = 16384, free: Int64 = 0) -> VerifiedCloudObjectCache {
        VerifiedCloudObjectCache(maximumBytes: 0, directory: dir, maximumDiskBytes: limit, minimumFreeBytes: free)
    }
    @discardableResult private func read(_ cache: VerifiedCloudObjectCache, _ remote: CacheFixtureRemote, key: String = "a", validator: String = "tag") async throws -> Data {
        try await cache.read(key: key, size: 4096, validator: validator, checksum: CoreFileIO.hash(Data(repeating: 42, count: 4096)), remote: remote)
    }
    func testConcurrentReadersShareOneVerifiedFetch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = CacheFixtureRemote(), value = cache(dir)
        let checksum = CoreFileIO.hash(Data(repeating: 42, count: 4096))
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<16 {
                group.addTask { try await value.read(key: "a", size: 4096, validator: "tag", checksum: checksum, remote: remote) }
            }
            for try await data in group { XCTAssertEqual(data.count, 4096) }
        }
        let count = await remote.count(); XCTAssertEqual(count, 1)
    }
    func testRestartDiskHitAndValidatorAndPathIsolation() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = CacheFixtureRemote()
        try await read(cache(dir), remote)
        let restarted = cache(dir)
        try await read(restarted, remote)
        var count = await remote.count(); XCTAssertEqual(count, 1)
        try await read(restarted, remote, validator: "other")
        try await read(restarted, remote, key: "b")
        count = await remote.count(); XCTAssertEqual(count, 3)
        await restarted.remove(key: "a")
        try await read(cache(dir), remote)
        count = await remote.count(); XCTAssertEqual(count, 4)
    }
    func testChecksumAndSizeIdentityDoNotAliasDiskHit() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = CacheFixtureRemote(), value = cache(dir)
        try await read(value, remote)
        do {
            _ = try await value.read(key: "a", size: 4096, validator: "tag", checksum: CoreFileIO.hash(Data("wrong".utf8)), remote: remote)
            XCTFail("Wrong checksum must not reuse verified cache")
        } catch { XCTAssertEqual(error as? StorageFailure, .integrity) }
        do {
            _ = try await value.read(key: "a", size: 2048, validator: "tag", checksum: CoreFileIO.hash(Data(repeating: 42, count: 4096)), remote: remote)
            XCTFail("Wrong size must not reuse verified cache")
        } catch { XCTAssertEqual(error as? StorageFailure, .integrity) }
        let count = await remote.count(); XCTAssertEqual(count, 3)
    }
    func testCorruptionAndRemovedFilesRefetch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = CacheFixtureRemote(), value = cache(dir)
        try await read(value, remote)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        try Data(repeating: 1, count: 4096).write(to: file)
        try await read(value, remote)
        var count = await remote.count(); XCTAssertEqual(count, 2)
        try FileManager.default.removeItem(at: file)
        try await read(value, remote)
        count = await remote.count(); XCTAssertEqual(count, 3)
    }
    func testEvictionBoundsBytesAndRefetches() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = CacheFixtureRemote(), value = cache(dir, limit: 4096)
        try await read(value, remote)
        try await read(value, remote, key: "b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
        try await read(value, remote)
        let count = await remote.count(); XCTAssertEqual(count, 3)
    }
    func testLowSpaceAndUnavailableCacheDoNotFailReads() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = CacheFixtureRemote(), value = cache(dir, free: Int64.max)
        try await read(value, remote); try await read(value, remote)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
        let count = await remote.count(); XCTAssertEqual(count, 2)
        let unavailable = dir.appendingPathComponent("file")
        try Data().write(to: unavailable)
        try await read(cache(unavailable), remote)
    }
    func testSymlinkAndDirectoryReplacementFallBackWithoutFollowing() async throws {
        let dir = directory(), other = directory(), moved = directory()
        defer { for url in [dir, other, moved] { try? FileManager.default.removeItem(at: url) } }
        let remote = CacheFixtureRemote(), value = cache(dir)
        try await read(value, remote)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = other.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        try await read(value, remote)
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        try FileManager.default.moveItem(at: dir, to: moved)
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: other)
        try await read(value, remote, key: "b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), ["sentinel"])
    }
}
