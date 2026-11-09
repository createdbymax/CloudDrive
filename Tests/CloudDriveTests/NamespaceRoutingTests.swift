import XCTest
import Foundation
@testable import CloudDrive

@MainActor final class NamespaceRoutingTests: XCTestCase {
    private let connection = Connection(endpoint: "https://routing-fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "fixture", accessKey: "synthetic", secretKey: "synthetic")
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("namespace-routing-" + UUID().uuidString) }
    private func object(_ key: String) -> CatalogObject { .init(key: key, size: 8, modified: Date(timeIntervalSince1970: 1234), etag: "fixture") }
    private func seedPhysicalCatalog(_ root: URL) async throws {
        var store: CatalogStore? = CatalogStore(directory: root.appendingPathComponent("Catalog/" + connection.fingerprint), fingerprint: connection.fingerprint, prefix: connection.prefix)
        let scan = try await store!.beginScan(fresh: true)
        try await store!.commit(page: .init(objects: [object("fixture/Old/song.wav"), object("fixture/PhysicalCopy/song.wav")], nextToken: nil), scan: scan)
        try await store!.finish(scanID: scan.id); store = nil
    }
    func testAuthoritativeNamespaceResultsHidePhysicalRelocationDuplicatesAndTombstones() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try await seedPhysicalCatalog(root)
        let catalog = CatalogController(root: root); catalog.configure(connection: connection)
        let physical = try await catalog.searchSnapshot(CatalogQuery(text: "song"))
        XCTAssertEqual(physical.count, 2)
        let logical = object("fixture/LogicalNewName/song.wav")
        catalog.namespaceSearch = { _ in [logical] }
        let unique = try await catalog.searchSnapshot(CatalogQuery(text: "song"))
        XCTAssertEqual(unique.map(\.key), [logical.key])
        // A logical deletion must stay hidden while physical source copies remain.
        catalog.namespaceSearch = { _ in [] }
        let deleted = try await catalog.searchSnapshot(CatalogQuery(text: "song"))
        XCTAssertTrue(deleted.isEmpty)
        catalog.namespaceSearch = { _ in nil }
        let legacy = try await catalog.searchSnapshot(CatalogQuery(text: "song"))
        XCTAssertEqual(legacy.count, 2)
    }
    func testUnavailableNamespaceNeverFallsBackToStaleRawObjectPaths() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try await seedPhysicalCatalog(root)
        let catalog = CatalogController(root: root); catalog.configure(connection: connection)
        catalog.namespaceSearch = { _ in throw CatalogFailure.storage }
        do { _ = try await catalog.searchSnapshot(CatalogQuery(text: "song")); XCTFail("An unavailable owner must remain an error") }
        catch CatalogFailure.storage { }
        catch { XCTFail("Unexpected namespace error: " + String(describing: type(of: error))) }
    }
    func testDirectUploadHandoffDoesNotCreateLegacyJobsOrModifyOriginal() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("original.wav"), bytes = Data("resident original".utf8)
        try bytes.write(to: source)
        let uploads = DirectUploadController(defaultDirectory: root.appendingPathComponent("LegacyQueue"), rememberLocation: false)
        var deliveries = 0
        uploads.namespaceEnqueue = { urls, destination in
            deliveries += 1; XCTAssertEqual(urls, [source]); XCTAssertEqual(destination.fingerprint, self.connection.fingerprint)
            return true
        }
        uploads.enqueue([source], connection: connection, excluded: [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while uploads.preparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(deliveries, 1); XCTAssertFalse(uploads.preparing)
        XCTAssertTrue(uploads.jobs.isEmpty); XCTAssertFalse(uploads.isActive)
        XCTAssertTrue(uploads.message.contains("drive owner"))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testEncryptionMarkerReservesDestinationBeforeCapabilityAndRoutesBrowsingToOwner() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Namespaces/" + connection.fingerprint)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent("encryption-selection.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "binding": connection.fingerprint, "keyID": String(repeating: "a", count: 64)]).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        let drive = Drive(root: root, binary: root.appendingPathComponent("unused"), helper: root.appendingPathComponent("unused-helper"), useKeychain: false, autoRecover: false)
        drive.connection = connection
        XCTAssertTrue(drive.namespaceEngine.encrypted)
        XCTAssertFalse(drive.namespaceEngine.enabled)
        XCTAssertTrue(drive.namespaceEngine.ownsDestination)
        XCTAssertFalse(drive.canDirectUpload)
        XCTAssertEqual(drive.browsingMountpoint, drive.namespaceEngine.mountpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("worker.json").path))
    }
    func testSelectedReadOnlyManagedModeBlocksLegacyWriterAndUploadFallbackEvenWhenStopped() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Namespaces/" + connection.fingerprint)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let capability = directory.appendingPathComponent("capability.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "binding": connection.fingerprint, "mode": "managed", "acceptsWrites": false]).write(to: capability)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: capability.path)
        let drive = Drive(root: root, binary: root.appendingPathComponent("not-a-legacy-backend"), helper: root.appendingPathComponent("unused"), useKeychain: false, autoRecover: false)
        drive.connection = connection
        XCTAssertTrue(drive.namespaceEngine.enabled); XCTAssertTrue(drive.namespaceEngine.readOnly)
        XCTAssertTrue(drive.namespaceEngine.ownsDestination); XCTAssertFalse(drive.namespaceEngine.running)
        XCTAssertFalse(drive.canDirectUpload)
        let file = root.appendingPathComponent("original.txt"); try Data("preserve".utf8).write(to: file)
        let uploads = drive.directUploads
        uploads.enqueue([file], connection: connection, excluded: [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while uploads.preparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(uploads.jobs.isEmpty); XCTAssertFalse(uploads.isActive)
        XCTAssertTrue(uploads.lastOperationFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("worker.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launch-intent.json").path))
        XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8))
    }
}
