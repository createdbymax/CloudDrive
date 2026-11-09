import XCTest
import SwiftUI
import AppKit
@testable import CloudDrive

@MainActor final class SpotlightPresentationTests: XCTestCase {
    func testShortcutPreferencesPreserveDefaultAndRejectUnknownValues() throws {
        let suite = "search-shortcut-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SearchShortcut.saved(in: defaults), .optionSpace)
        defaults.set("future-unsupported", forKey: SearchShortcut.preferenceKey)
        XCTAssertEqual(SearchShortcut.saved(in: defaults), .optionSpace)
        defaults.set(SearchShortcut.controlOptionO.rawValue, forKey: SearchShortcut.preferenceKey)
        XCTAssertEqual(SearchShortcut.saved(in: defaults), .controlOptionO)
        defaults.set(SearchShortcut.disabled.rawValue, forKey: SearchShortcut.preferenceKey)
        XCTAssertEqual(SearchShortcut.saved(in: defaults), .disabled)
        XCTAssertNotEqual(SearchShortcut.controlOptionO.keyCode, SearchShortcut.optionSpace.keyCode)
        XCTAssertNotEqual(SearchShortcut.controlOptionO.modifiers, SearchShortcut.optionSpace.modifiers)
    }
    func testGlassPanelRendersSavedIndexWithoutConnecting() async throws {
        _ = NSApplication.shared
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            throw XCTSkip("The desktop is locked or at login. Keyboard-focus qualification requires an unlocked desktop.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-presentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = Connection(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "Drive", accessKey: "synthetic", secretKey: "synthetic")
        var store: CatalogStore? = CatalogStore(directory: root.appendingPathComponent("Catalog/" + connection.fingerprint), fingerprint: connection.fingerprint, prefix: connection.prefix)
        let scan = try await store!.beginScan(fresh: true)
        let names = ["Music/Night Drive — Final Master.wav", "Music/Album Artwork.png", "Projects/Brand Film.mov", "Documents/Project notes.pdf", "Music/Drum stems.zip", "Documents/Release checklist.md"]
        let items = names.enumerated().map { CatalogObject(key: "Drive/" + $0.element, size: Int64($0.offset + 1) * 10_485_760, modified: Date(), etag: "fixture") }
        try await store!.commit(page: InventoryPage(objects: items, nextToken: nil), scan: scan)
        try await store!.finish(scanID: scan.id); store = nil
        let drive = Drive(root: root, binary: root.appendingPathComponent("unused"), helper: root.appendingPathComponent("unused-helper"), useKeychain: false, autoRecover: false)
        drive.connection = connection
        _ = try await drive.catalog.searchSnapshot(CatalogQuery(text: ""))
        let controller = SpotlightPanelController(drive: drive)
        controller.show()
        defer { controller.dismiss() }
        try await Task.sleep(for: .milliseconds(800))
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.contentView is NSHostingView<SpotlightSearchView> })
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(drive.running); XCTAssertFalse(drive.mounted)
        XCTAssertEqual(drive.catalog.summary.count, 6)
        let host = try XCTUnwrap(panel.contentView)
        host.layoutSubtreeIfNeeded()
        controller.dismiss()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.contentView)
        controller.show()
        XCTAssertTrue(panel.isVisible)
        panel.cancelOperation(nil)
        XCTAssertFalse(panel.isVisible)
    }
}
