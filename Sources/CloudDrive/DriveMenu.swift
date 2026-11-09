import SwiftUI
import AppKit

/// Native menu rows keep the system's material, appearance and keyboard behavior.
/// All actions use the app delegate's existing controller.
struct DriveMenu: View {
    @ObservedObject var drive: Drive
    var showSearch: () -> Void = {}
    var showUploads: () -> Void = {}
    @Environment(\.openWindow) private var openWindow
    @State private var clock = Date()

    var body: some View {
        let now = max(clock, Date())
        let status = drive.presentation(at: now)
        Group {
            if status.tone != .normal || drive.lastOperationFailed {
                Text(status.title)
                if !drive.operationBusy, drive.activityAvailable,
                   UploadFreshness.isFresh(drive.uploadSampledAt, at: now),
                   let snapshot = drive.uploadProgress, !snapshot.isEmpty {
                    Text(UploadMetricText.speed(snapshot.speed))
                }
                Divider()
            }

            if drive.canResumeMove {
                if drive.finderMoves?.jobs != nil {
                    Button("Review interrupted moves…") { showWindow("recovery") }
                } else {
                    Button("Resume move") { Task { await drive.resumeMove() } }
                }
            }
            if drive.finderMounted {
            Button { drive.openDrive() } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            } else if drive.canConnect {
                Button("Connect Drive") { Task { await drive.start() } }
            }
            Button { showSearch() } label: {
                Label("Search Drive…", systemImage: "magnifyingglass")
            }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button { showUploads(); showWindow("dashboard") } label: {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
            }
            DirectUploadMenu(uploads: drive.directUploads, canResume: drive.canDirectUpload, connection: drive.connection)
            Button { showWindow("status") } label: {
                Label("Show CloudDrive", systemImage: "externaldrive")
            }
            Button { showWindow("dashboard") } label: {
                Label("Manage Drive…", systemImage: "externaldrive")
            }

            if status.tone == .attention || drive.lastOperationFailed {
                Divider()
                Button { showWindow("recovery") } label: {
                    Label("Finder recovery…", systemImage: "cross.case")
                }
            }
            if drive.finderMounted || drive.storageWorkerRunning || drive.canEject {
                Button { Task { await drive.eject() } } label: {
                    Label(drive.ejectActionTitle, systemImage: "eject")
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

private struct DirectUploadMenu: View {
    @ObservedObject var uploads: DirectUploadController
    let canResume: Bool
    let connection: Connection
    var body: some View {
        if uploads.isActive {
            Text("Direct uploads: \(Int(uploads.progress * 100))% confirmed")
            Button("Pause direct uploads") { uploads.pause() }
        } else if uploads.jobs.contains(where: { !$0.terminal }) {
            Button("Resume direct uploads") { uploads.resume(connection: connection, bytesPerSecond: uploads.uploadRate()) }.disabled(!canResume)
        }
    }
}
