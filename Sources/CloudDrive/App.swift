import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // Own the one controller before any window or menu appears.
    let drive = Drive()
    lazy var updates = UpdateController(canInstall: { [weak self] in self?.drive.canQuit == true })
    func applicationDidFinishLaunching(_ notification: Notification) { _ = updates }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !drive.canQuit else { return .terminateNow }
        let alert = NSAlert()
        if drive.busy {
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

@main struct CloudDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("CloudDrive", id: "dashboard") {
            ContentView(drive: delegate.drive)
        }.defaultSize(width: 480, height: 310)
        .commands { CommandGroup(after: .appInfo) { UpdateMenu(updates: delegate.updates) } }
        Window("Transfers", id: "transfers") {
            TransfersView(drive: delegate.drive)
        }.defaultSize(width: 620, height: 600)
        Window("Recovery", id: "recovery") {
            RecoveryView(drive: delegate.drive).padding(24).frame(minWidth: 480, minHeight: 300)
        }.defaultSize(width: 540, height: 380)
        Settings { DriveSettingsView(drive: delegate.drive) }
        MenuBarExtra("CloudDrive", systemImage: "externaldrive") {
            DriveMenu(drive: delegate.drive)
            Divider()
            UpdateMenu(updates: delegate.updates)
        }.menuBarExtraStyle(.menu)
    }
}
