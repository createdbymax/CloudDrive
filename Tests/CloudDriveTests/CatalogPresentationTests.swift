import XCTest
import SwiftUI
import AppKit
@testable import CloudDrive

@MainActor final class CatalogPresentationTests: XCTestCase {
    private var root: URL!
    private let connection = Connection(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "prefix", accessKey: "synthetic-access", secretKey: "synthetic-secret")
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-presentation-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func waitLoaded(_ controller: CatalogController) async throws {
        let deadline = Date().addingTimeInterval(3)
        while controller.loading {
            guard Date() < deadline else { XCTFail("Catalog load timeout"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testOfflineControllerRestoreSearchAndDestinationChangeClearsResults() async throws {
        var seed: CatalogStore? = CatalogStore(directory: root.appendingPathComponent("Catalog/" + connection.fingerprint), fingerprint: connection.fingerprint, prefix: connection.prefix)
        let scan = try await seed!.beginScan(fresh: true)
        try await seed!.commit(page: InventoryPage(objects: [CatalogObject(key: "prefix/Album/Vocals.wav",size: 42, modified: Date(),etag: "opaque")],nextToken:nil),scan:scan)
        try await seed!.finish(scanID:scan.id); seed = nil
        let controller = CatalogController(root: root, makeRemote: { _ in fatalError("Offline restore/search must not create a remote") })
        controller.configure(connection: connection); try await waitLoaded(controller)
        XCTAssertEqual(controller.summary.count,1)
        await controller.search(CatalogQuery(text:"voc")); XCTAssertEqual(controller.results.count,1); XCTAssertFalse(controller.searching)
        var other = connection; other.prefix = "another"
        controller.configure(connection:other)
        XCTAssertTrue(controller.results.isEmpty); XCTAssertEqual(controller.summary.count,0)
        try await waitLoaded(controller)
        await controller.search(CatalogQuery(text:"voc")); XCTAssertTrue(controller.results.isEmpty)
    }
    func testNewerQueryWinsAndErrorsDoNotRetainWrongResults() async throws {
        let controller = CatalogController(root: root)
        controller.configure(connection: connection); try await waitLoaded(controller)
        let old = Task { await controller.search(CatalogQuery(text:"old")) }
        await Task.yield()
        await controller.search(CatalogQuery(text:"***"))
        await old.value
        XCTAssertFalse(controller.searchError.isEmpty); XCTAssertTrue(controller.results.isEmpty)
    }
    func testLateInventoryResponseCannotPopulateDifferentDestination() async throws {
        let remote = DelayedCatalogInventory()
        let controller = CatalogController(root:root,makeRemote:{ _ in remote })
        controller.configure(connection:connection); try await waitLoaded(controller)
        controller.refresh()
        let deadline = Date().addingTimeInterval(3)
        while !(await remote.entered) {
            guard Date() < deadline else { XCTFail("Scan did not start"); return }
            try await Task.sleep(for:.milliseconds(5))
        }
        var other = connection; other.prefix = "other"
        controller.configure(connection:other); try await waitLoaded(controller)
        await remote.release()
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(controller.summary.count,0); XCTAssertFalse(controller.scanning)
        await controller.search(CatalogQuery(text:"private")); XCTAssertTrue(controller.results.isEmpty)
    }
    func testNativeSearchWindowRendersOfflineWithoutMountOrKeychain() async throws {
        _ = NSApplication.shared
        var seed: CatalogStore? = CatalogStore(directory: root.appendingPathComponent("Catalog/" + connection.fingerprint),fingerprint:connection.fingerprint,prefix:connection.prefix)
        let scan = try await seed!.beginScan(fresh:true)
        let items = ["Album/Vocals Final.wav", "Album/Drum stems.wav", "Client Work/Brand Film.mov", "Documents/Project notes.pdf"].enumerated().map {
            CatalogObject(key:"prefix/" + $0.element,size:Int64($0.offset+1)*10_485_760,modified:Date(timeIntervalSince1970:1_793_664_000),etag:"synthetic")
        }
        try await seed!.commit(page:InventoryPage(objects:items,nextToken:nil),scan:scan)
        try await seed!.finish(scanID:scan.id); seed = nil
        let drive = Drive(root: root, binary: root.appendingPathComponent("unused-backend"), helper: root.appendingPathComponent("unused-helper"),useKeychain:false,autoRecover:false)
        drive.connection = connection
        let controller = drive.catalog
        try await waitLoaded(controller)
        await controller.search(CatalogQuery(text:""))
        let host = NSHostingView(rootView: SearchView(drive:drive,catalog:controller))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.contentView = host; window.title = "Search Drive — synthetic offline fixture"
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for:.milliseconds(250))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width,600); XCTAssertFalse(drive.mounted); XCTAssertFalse(drive.running)
        if let path = ProcessInfo.processInfo.environment["CLOUDDRIVE_SEARCH_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try png.write(to:URL(fileURLWithPath:path))
        }
    }
}

private actor DelayedCatalogInventory: ObjectInventoryRemote {
    private(set) var entered = false
    private var continuation: CheckedContinuation<InventoryPage,Never>?
    func list(token: String?) async throws -> InventoryPage {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume(returning:InventoryPage(objects:[CatalogObject(key:"prefix/private.wav",size:42,modified:Date(),etag:"tag")],nextToken:nil))
        continuation = nil
    }
    func isMissing(key:String) async throws -> Bool { false }
}
