import AppKit
import SwiftUI

/// Daily status and file access. Detailed controls live in the management window.
struct CompactDriveView: View {
    @ObservedObject var drive: Drive
    let showSearch: () -> Void
    @Environment(\.openWindow) private var openWindow

    @State private var copying = false
    @State private var targeted = false
    @State private var dropError: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = drive.presentation(at: Date())
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CloudDrive").font(.headline)
                    if drive.needsSetup {
                        Text("Connect your storage to get started.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Label {
                            Text(status.title)
                        } icon: {
                            Image(systemName: status.symbol)
                                .foregroundStyle(status.tone == .attention ? Color.orange :
                                    (status.symbol == "checkmark.circle" ? Color.green : Color.secondary))
                        }
                        .font(.subheadline)
                        Text(copying ? "Copying to your drive…" : targeted ? "Drop to copy to CloudDrive" : status.subtitle).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if drive.needsSetup {
                    Button("Set Up Drive…") { openWindow(id: "dashboard") }
                        .buttonStyle(.borderedProminent)
                } else if drive.finderMounted {
                    Button("Open in Finder") { drive.openDrive() }
                        .buttonStyle(.borderedProminent).keyboardShortcut("o", modifiers: .command)
                } else if drive.canConnect {
                    Button("Connect Drive") { Task { await drive.start() } }.buttonStyle(.borderedProminent)
                } else if status.tone == .attention {
                    Button("Review…") { openWindow(id: "dashboard") }
                }
                Menu {
                    if writable {
                        Button("Add Files…") { Task { await chooseFiles() } }.disabled(copying)
                    }
                    Button("Search Drive…", action: showSearch).disabled(drive.needsSetup)
                    Button("Manage Drive…") { openWindow(id: "dashboard") }
                    SettingsLink { Text("Settings…") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More drive options")
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !copying, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
                do { return startCopy(urls, to: try drive.dropMount()) }
                catch {
                    dropError = error.localizedDescription
                    return false
                }
            } isTargeted: { hovering in
                targeted = hovering && !copying && writable
            }
            .padding(14)
        }
        .alert("Couldn’t copy to CloudDrive", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK") { dropError = nil }
        } message: { Text(dropError ?? "") }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
    private var writable: Bool {
        drive.canAcceptMountedDrop
    }

    @MainActor private func chooseFiles() async {
        do {
            let destination = try drive.dropMount()
            let panel = NSOpenPanel()
            panel.title = "Add files to CloudDrive"
            panel.prompt = "Add to Drive"
            panel.canChooseFiles = true
            panel.canChooseDirectories = destination.type.lowercased() != "nfs"
            panel.treatsFilePackagesAsDirectories = true
            panel.allowsMultipleSelection = true
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            guard await panel.beginSheetModal(for: window) == .OK else { return }
            guard try drive.dropMount() == destination else { throw POSIXError(.ESTALE) }
            _ = startCopy(panel.urls, to: destination)
        } catch { dropError = error.localizedDescription }
    }

    @MainActor private func startCopy(_ urls: [URL], to target: MountEntry) -> Bool {
        guard !copying, !urls.isEmpty else { return false }
        copying = true
        Task { @MainActor in
            defer { copying = false }
            do { try await Task.detached(priority: .utility) { try MountedDrop.copy(urls, to: target) }.value }
            catch { dropError = error.localizedDescription }
        }
        return true
    }

}
