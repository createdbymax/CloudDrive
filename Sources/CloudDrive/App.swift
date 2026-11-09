import SwiftUI
import AppKit
import CloudDriveCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // Own the one controller before any window or menu appears.
    let qualificationCLI = R2QualificationLaunch.requested(arguments: CommandLine.arguments)
    let drive: Drive
    private let connectIndexed = CommandLine.arguments.dropFirst().elementsEqual(["--connect-indexed-drive"])
    override init() {
        drive = R2QualificationLaunch.requested(arguments: CommandLine.arguments)
            ? Drive(useKeychain: false, autoRecover: false) : Drive(autoRecover: !connectIndexed)
        super.init()
    }
    let navigation = DashboardNavigation()
    lazy var spotlight = SpotlightPanelController(drive: drive)
    lazy var updates = UpdateController(canInstall: { [weak self] in self?.drive.canQuit == true })
    func applicationDidFinishLaunching(_ notification: Notification) {
        if qualificationCLI {
            NSApp.setActivationPolicy(.prohibited)
            #if DEBUG
            Task { await R2QualificationLaunch.run(arguments: CommandLine.arguments, root: drive.root) }
            #endif
            return
        }
        _ = updates; spotlight.registerShortcut(); drive.catalog.enableAutomaticUpdates()
        if connectIndexed {
            Task {
                await drive.recover()
                await drive.connectIndexedDrive()
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !drive.canQuit else { return .terminateNow }
        if drive.directUploads.preparing {
            let alert = NSAlert(); alert.messageText = "Upload files are being prepared"
            alert.informativeText = "Wait for preparation or records recovery to finish, then quit. File contents are not being copied to local storage."
            alert.addButton(withTitle: "Keep Open"); alert.runModal()
            return .terminateCancel
        }
        if !drive.directUploads.canQuit {
            let alert = NSAlert()
            alert.messageText = "Pause uploads and quit?"
            alert.informativeText = "Confirmed multipart progress is saved. Reopen CloudDrive and choose Resume with the original source drive connected. Incomplete parts expire according to your R2 bucket policy."
            alert.addButton(withTitle: "Keep Uploading")
            alert.addButton(withTitle: "Pause and Quit")
            guard !drive.directUploads.preparing, alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            Task {
                await drive.directUploads.pauseAndWait()
                sender.reply(toApplicationShouldTerminate: drive.canQuit)
            }
            return .terminateLater
        }
        let alert = NSAlert()
        if drive.operationBusy {
            alert.messageText = "A drive operation is in progress"
            alert.informativeText = "Wait for it to finish, or cancel the operation in CloudDrive before quitting."
            alert.addButton(withTitle: "Keep Open")
            alert.runModal()
            return .terminateCancel
        }
        alert.messageText = "Quit CloudDrive?"
        alert.informativeText = "Eject first to finish uploads and stop the drive. If recovery is blocked, you can quit only the app: the storage worker will keep running, and the local cache and recovery record will be preserved. Reopen CloudDrive to recover the worker and eject it."
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Quit App, Keep Worker")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main enum CloudDriveEntry {
    @MainActor static func main() {
        #if DEBUG
        if CommandLine.arguments.dropFirst().contains(where: { ["--logic-move-copy", "--qualify-logic-move-copy"].contains($0) }) {
            guard CommandLine.arguments.count == 2 else { Darwin.exit(64) }
            let probe = CommandLine.arguments[1] == "--qualify-logic-move-copy"
            Task { Darwin.exit(await LogicMoveHelper.run(probe: probe)) }
            dispatchMain()
        }
        if R2QualificationLaunch.requested(arguments: CommandLine.arguments) {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        #endif
        CloudDriveApp.main()
    }
}

struct CloudDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("CloudDrive", id: "status") {
            CompactDriveView(drive: delegate.drive, showSearch: { delegate.spotlight.show() })
                .modifier(FinderURLHandler(drive: delegate.drive, navigation: delegate.navigation))
        }.windowResizability(.contentSize)
        Window("Manage CloudDrive", id: "dashboard") {
            ContentView(drive: delegate.drive, navigation: delegate.navigation, showSearch: { delegate.spotlight.show() })
        }.defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(after: .appInfo) { UpdateMenu(updates: delegate.updates) }
            CommandGroup(after: .textEditing) { SearchWindowCommand(search: delegate.spotlight) }
        }
        Window("Search Drive", id: "search") {
            SearchView(drive: delegate.drive, catalog: delegate.drive.catalog)
        }.defaultSize(width: 820, height: 560)
        Window("Recovery", id: "recovery") {
            RecoveryView(drive: delegate.drive).padding(24).frame(minWidth: 480, minHeight: 300)
        }.defaultSize(width: 540, height: 380)
        Settings {
            DriveSettingsView(drive: delegate.drive, spotlight: delegate.spotlight)
        }
        MenuBarExtra("CloudDrive", systemImage: "externaldrive") {
            DriveMenu(drive: delegate.drive, showSearch: { delegate.spotlight.show() }, showUploads: { delegate.navigation.showUploads() })
            SearchShortcutStatus(search: delegate.spotlight)
            Divider()
            UpdateMenu(updates: delegate.updates)
        }.menuBarExtraStyle(.menu)
    }
}

private struct SearchWindowCommand: View {
    @ObservedObject var search: SpotlightPanelController
    var body: some View {
        Button("Search Drive…") { search.show() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}

private struct SearchShortcutStatus: View {
    @ObservedObject var search: SpotlightPanelController
    var body: some View {
        if let error = search.shortcutError { Text(error) }
    }
}

/// Custom URL origins are untrusted. Parse narrowly, validate the selected mount,
/// confirm mutations, then let the owner revalidate against its current session.
private struct FinderURLHandler: ViewModifier {
    @ObservedObject var drive: Drive
    @ObservedObject var navigation: DashboardNavigation
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View { content.onOpenURL(perform: receive) }

    private func receive(_ url: URL) {
        do {
            let request = try FinderActionRequest(url: url)
            if request.action == .activity {
                navigation.showUploads(); openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true)
                return
            }
            if request.action == .move {
                guard let session = drive.movePickerSession, let path = request.path else { throw FinderActionPromptFailure.unavailable }
                _ = try request.relativeComponents(under: drive.mountpoint)
                let item = URL(fileURLWithPath: path, isDirectory: false)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
                navigation.destination = .drive
                Task { await drive.chooseDestinationAndMove(source: item, session: session) }
                return
            }
            guard drive.finderMounted, drive.namespaceEngine.enabled, !drive.namespaceEngine.readOnly,
                  !request.paths.isEmpty else { throw FinderActionPromptFailure.unavailable }
            _ = try request.relativeSelections(under: drive.browsingMountpoint)
            let binding = drive.connection.fingerprint
            let selection = FinderActionConfirmation.selectionLabel(paths: request.paths)
            let alert = NSAlert()
            alert.messageText = request.action == .keepDownloaded ? "Keep \(selection) downloaded?" : "Free local space for \(selection)?"
            alert.informativeText = request.action == .keepDownloaded
                ? "Download the selected items for offline use on this Mac. This request came from another application. Review every selected path below."
                : "Release eligible downloaded data for the selected items. Pending changes remain protected; opening them again may need the internet. This request came from another application. Review every selected path below."
            let pathsView = NSTextView.scrollableTextView()
            pathsView.frame = NSRect(x: 0, y: 0, width: 440, height: min(200, max(64, request.paths.count * 32)))
            if let text = pathsView.documentView as? NSTextView {
                text.string = request.paths.joined(separator: "\n\n")
                text.isEditable = false; text.isSelectable = true
                text.font = NSFont.systemFont(ofSize: 11)
                text.setAccessibilityLabel("Selected file paths")
            }
            alert.accessoryView = pathsView
            alert.addButton(withTitle: request.action == .keepDownloaded ? "Keep Downloaded" : "Free Local Space")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard drive.connection.fingerprint == binding else { throw FinderActionPromptFailure.unavailable }
            Task {
                guard drive.connection.fingerprint == binding else { return }
                await drive.namespaceEngine.handleFinderAction(request)
                navigation.showUploads(); openWindow(id: "dashboard")
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Finder action unavailable"
            alert.informativeText = "Connect the drive and select an item inside it."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
}
private enum FinderActionPromptFailure: Error { case unavailable }

enum FinderActionConfirmation {
    static func selectionLabel(paths: [String]) -> String {
        paths.count == 1 ? "“" + URL(fileURLWithPath: paths[0], isDirectory: false).lastPathComponent + "”" : "\(paths.count) items"
    }
}
