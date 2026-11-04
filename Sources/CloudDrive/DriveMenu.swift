import SwiftUI
import AppKit

/// Native menu rows keep the system's material, appearance and keyboard behavior.
/// All actions use the app delegate's existing controller.
struct DriveMenu: View {
    @ObservedObject var drive: Drive
    @Environment(\.openWindow) private var openWindow
    @State private var clock = Date()

    var body: some View {
        let now = max(clock, Date())
        let status = drive.presentation(at: now)
        Group {
            if status.tone != .normal || drive.lastOperationFailed {
                Text(status.title)
                if !drive.busy, drive.activityAvailable,
                   UploadFreshness.isFresh(drive.uploadSampledAt, at: now),
                   let snapshot = drive.uploadProgress, !snapshot.isEmpty {
                    Text(UploadMetricText.speed(snapshot.speed))
                }
                Divider()
            }

            Button { drive.openDrive() } label: {
                Label("Open in Finder", systemImage: "folder")
            }.disabled(!drive.mounted)
            Button { showWindow("transfers") } label: {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
            }
            Button { showWindow("dashboard") } label: {
                Label("Show CloudDrive", systemImage: "externaldrive")
            }

            if status.tone == .attention || drive.lastOperationFailed || drive.mountState == .unmounted {
                Divider()
                Button { showWindow("recovery") } label: {
                    Label("Recovery…", systemImage: "cross.case")
                }
            }
            if drive.mounted || drive.running || drive.canEject {
                Button { Task { await drive.eject() } } label: {
                    Label("Eject", systemImage: "eject")
                }.disabled(!drive.canEject)
            }

            Divider()
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }.keyboardShortcut(",", modifiers: .command)
            Divider()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit CloudDrive", systemImage: "power")
            }.keyboardShortcut("q", modifiers: .command)
        }
        .task {
            // A stalled control request must not leave an old speed visible in an
            // open menu. This clock changes presentation only, never worker state.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                clock = Date()
            }
        }
    }

    private func showWindow(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
