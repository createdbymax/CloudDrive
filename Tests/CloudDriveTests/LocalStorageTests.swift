import XCTest
import Darwin
@testable import CloudDrive

final class LocalStorageTests: XCTestCase {
    func testSparseAllocationAndSymlinkExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("Cache/connection")
        let data = cache.appendingPathComponent("vfs/fixture")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = data.appendingPathComponent("sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.seek(toOffset: 1024)
        try handle.write(contentsOf: Data(repeating: 1, count: 4096))
        try handle.close()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: URL(fileURLWithPath: "/"))
        // An excluded drive contains a large local fixture; even metadata is skipped.
        let drive = root.appendingPathComponent("Drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1024 * 1024).write(to: drive.appendingPathComponent("ignored"))
        let nativeDrive = root.appendingPathComponent("Instant Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDrive, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 2 * 1024 * 1024).write(to: nativeDrive.appendingPathComponent("ignored", isDirectory: false))
        let snapshot = LocalStorageScanner.scan(root: root, cache: cache)
        XCTAssertTrue(snapshot.complete)
        XCTAssertGreaterThan(snapshot.dataCacheBytes, 0)
        XCTAssertLessThan(snapshot.dataCacheBytes, 1024 * 1024)
        XCTAssertLessThan(snapshot.otherBytes, 1024 * 1024)
        XCTAssertGreaterThan(snapshot.freeBytes ?? 0, 0)
    }

    func testBoundedAndMissingScansAreIncomplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("one"))
        XCTAssertFalse(LocalStorageScanner.scan(root: root, cache: root, maxEntries: 0).complete)
        XCTAssertFalse(LocalStorageScanner.scan(root: root.appendingPathComponent("missing"), cache: root).complete)
    }
}
