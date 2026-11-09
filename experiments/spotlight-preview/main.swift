// Isolated UI harness: synthetic catalog, no Keychain, remote, worker or mount.
import AppKit
import SwiftUI
@testable import CloudDrive

@MainActor final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var controls: NSWindow?
    var drive: Drive?
    var search: SpotlightPanelController?
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudDrive-Spotlight-Preview-" + UUID().uuidString)
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        appMenu.addItem(withTitle: "Search Drive", action: #selector(showSearch), keyEquivalent: "f").target = self
        appMenu.addItem(withTitle: "Light Appearance", action: #selector(light), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: "Dark Appearance", action: #selector(dark), keyEquivalent: "d").target = self
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        let controls = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 380, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        controls.title = "Spotlight Preview Controls"
        controls.isReleasedWhenClosed = false
        controls.contentView = NSHostingView(rootView: VStack(spacing: 16) {
            Text("Synthetic drive · no bucket connection").font(.headline)
            Button("Show Search (Option–Space)") { self.search?.show() }
            HStack {
                Button("Light appearance") { self.light() }
                Button("Dark appearance") { self.dark() }
            }
        }.padding(24).frame(width: 380, height: 180))
        self.controls = controls; controls.makeKeyAndOrderFront(nil)
        _ = Task {
            let connection = Connection(endpoint: "https://fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "Drive", accessKey: "synthetic", secretKey: "synthetic")
            var store: CatalogStore? = CatalogStore(directory: root.appendingPathComponent("Catalog/" + connection.fingerprint), fingerprint: connection.fingerprint, prefix: connection.prefix)
            let scan = try await store!.beginScan(fresh: true)
            let names = ["Music/Night Drive — Final Master.wav", "Music/Album Artwork.png", "Projects/Brand Film.mov", "Documents/Project notes.pdf", "Music/Drum stems.zip", "Documents/Release checklist.md"]
            let objects = names.enumerated().map { CatalogObject(key: "Drive/" + $0.element, size: Int64($0.offset + 1) * 10_485_760, modified: Date(), etag: "fixture") }
            try await store!.commit(page: InventoryPage(objects: objects, nextToken: nil), scan: scan)
            try await store!.finish(scanID: scan.id); store = nil
            let drive = Drive(root: root, binary: root.appendingPathComponent("unused"), helper: root.appendingPathComponent("unused-helper"), useKeychain: false, autoRecover: false)
            drive.connection = connection
            self.drive = drive
            _ = try await drive.catalog.searchSnapshot(CatalogQuery(text: ""))
            let search = SpotlightPanelController(drive: drive)
            self.search = search; search.registerShortcut(); search.show()
            try? (search.shortcutError ?? "registered").write(to: root.appendingPathComponent("shortcut-status.txt"), atomically: true, encoding: .utf8)
        }
    }
    @objc func showSearch() { search?.show() }
    @objc func light() { NSApp.appearance = NSAppearance(named: .aqua) }
    @objc func dark() { NSApp.appearance = NSAppearance(named: .darkAqua) }
    func applicationWillTerminate(_ notification: Notification) { try? FileManager.default.removeItem(at: root) }
}
@main @MainActor enum PreviewMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
