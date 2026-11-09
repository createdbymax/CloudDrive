import SwiftUI

struct DriveSettingsView: View {
    @ObservedObject var drive: Drive
    var spotlight: SpotlightPanelController? = nil
    @State private var selectedUploadLimit: UploadLimit = .unlimited
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            transfers.tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            storage.tabItem { Label("Storage", systemImage: "internaldrive") }
            NamespaceManagementView(drive: drive).tabItem { Label("File management", systemImage: "folder") }
            connection.tabItem { Label("Connection", systemImage: "network") }
            diagnostics.tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }.padding(20).frame(width: 700, height: 560)
    }

    private var transfers: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Upload speed").font(.headline)
            if !drive.namespaceEngine.ownsDestination && drive.directUploads.hasUnfinishedOrUnavailableQueue {
                DirectUploadTuningView(uploads: drive.directUploads)
            }
            Picker("Upload limit", selection: $selectedUploadLimit) {
                ForEach(UploadLimit.allCases) { limit in Text(limit.label).tag(limit) }
            }.disabled(!canChangeUploadLimit)
            Button(drive.storageWorkerRunning ? "Apply upload limit" : "Save upload limit") {
                Task { await drive.changeUploadLimit(selectedUploadLimit) }
            }.disabled(!canChangeUploadLimit)
            metricRow("Saved upload limit", value: drive.uploadLimit.label)
            if drive.namespaceEngine.ownsDestination {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let rate = UploadFreshness.isFresh(drive.namespaceEngine.statusSampledAt, at: context.date)
                        ? drive.namespaceEngine.appliedUploadBytesPerSecond : nil
                    metricRow("Applied upload limit", value: UploadLimit.namespaceLabel(rate))
                    if rate == nil {
                        Text("The drive’s applied limit has not been confirmed. Reconnect or retry before assuming the limit is active.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if drive.running {
                metricRow("Applied upload limit", value: drive.appliedUploadLimit?.label ?? "Unknown")
                if drive.appliedUploadLimit == nil {
                    Text("The worker’s applied limit has not been confirmed. A requested value is not shown as applied until readback succeeds.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("The saved limit applies when the drive next connects.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Limits use Mbps (megabits per second). Transfer speed uses MB/s (megabytes per second): 8 Mbps is 1 MB/s. Downloads remain unlimited.").font(.callout).foregroundStyle(.secondary)
            Text(drive.namespaceEngine.ownsDestination ? "The upload limit applies to background cloud writes. Opening and downloading files uses a separate path. Pause and Resume syncing are available in Activity." : "Finder uploads retry automatically. Use Retry Now to retry a waiting file.").font(.callout).foregroundStyle(.secondary)
            OperationFeedback(drive: drive)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { selectedUploadLimit = drive.uploadLimit }
            .onChange(of: drive.uploadLimit) { _, value in selectedUploadLimit = value }
        }
    }

    private var canChangeUploadLimit: Bool {
        if drive.namespaceEngine.ownsDestination { return drive.namespaceEngine.running && !drive.operationBusy }
        return !drive.busy && drive.mountState != .blocked && drive.mountState != .checking && (drive.running || drive.canDirectUpload)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CloudDrive").font(.title2.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")").foregroundStyle(.secondary)
            LoginItemSettingsView()
            if let spotlight { SearchShortcutSettings(controller: spotlight) }
            Text("Keep CloudDrive running while using the Finder drive. Closing a window leaves your drive connected. Eject before quitting to finish pending uploads.")
            Text(drive.namespaceEngine.enabled ? "Use one actively writing Mac at a time. Keep downloaded is available from file actions in Search. File version history is not available. Optional experimental encryption is available only when setting up a new managed drive in File management." : "Use one actively writing Mac at a time. Offline downloads require File management. File version history is not available. Optional experimental encryption is available only when setting up a new managed drive in File management.").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StorageSummary(drive: drive)
                Divider()
                Text("Physical storage on this Mac").font(.headline)
                if let snapshot = drive.storageSnapshot {
                    metricRow("Cached file data", value: size(snapshot.dataCacheBytes))
                    metricRow("Metadata and other app files", value: size(snapshot.otherBytes))
                    metricRow("Free Mac space", value: snapshot.freeBytes.map(size) ?? "Unavailable")
                    Text(snapshot.complete ? "Measured \(snapshot.measuredAt.formatted(date: .omitted, time: .shortened)). Values can change during uploads and reads." : "Partial scan: app allocation values are lower bounds. Some entries were unavailable or the scan reached its limit.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Physical allocation has not been measured.").foregroundStyle(.secondary)
                }
                Text("Pending-write allocation and recent-read allocation cannot currently be separated reliably. Logical cloud size is not measured here.").font(.caption).foregroundStyle(.secondary)
                Button("Refresh storage measurement") { Task { await drive.refreshLocalStorage() } }
                Text("Keep at least 10 GB free. Large writes may need their full size staged locally. Clean data is reclaimed automatically; pending and open data can exceed the cache target. Originals outside the drive keep using their original space.").font(.callout).foregroundStyle(.secondary)
                Button("Show Local Storage") { drive.showStorage() }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.task { await drive.refreshLocalStorage() }
    }

    private var connection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your R2 connection").font(.headline)
                ConnectionFields(drive: drive)
                Text("Safely eject before changing a destination. Each destination has its own cache; pending data is retained.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Save and Connect") { Task { await drive.start() } }.disabled(!drive.canConnect)
                    Button("Eject") { Task { await drive.eject() } }.disabled(!drive.canEject)
                }
                RecoveryActions(drive: drive)
                OperationFeedback(drive: drive)
            }
        }
    }

    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                R2QualificationView(connection: drive.connection, root: drive.root)
                Divider()
                Text(drive.status).font(.headline)
                Text(drive.uploadStatus)
                if !drive.detail.isEmpty { Text(drive.detail).font(.callout).textSelection(.enabled) }
                Button("Test Bucket with a 1 MB File") { Task { await drive.verifyBucket() } }.disabled(!drive.canVerifyBucket)
                if let reason = drive.bucketVerificationBlockedReason {
                    Label(reason, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                }
                Text("The test creates a disposable 1 MiB file, downloads it independently and compares SHA-256. A pass applies to that fixture only.").font(.caption).foregroundStyle(.secondary)
                if !drive.verification.isEmpty { Label(drive.verification, systemImage: "checkmark.circle").font(.callout).textSelection(.enabled) }
                OperationFeedback(drive: drive)
                RecentActivityView(drive: drive)
                Text(drive.namespaceEngine.enabled ? "File management uses its selected filesystem adapter and a local owner process. Connection details are available in File management." : "Finder uses a loopback NFS server accessible to other processes on this Mac. No LAN listener is opened.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metricRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 16)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(value)
    }
    private func size(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

private struct DirectUploadTuningView: View {
    @ObservedObject var uploads: DirectUploadController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Parallel file uploads", selection: Binding(get: { uploads.concurrency }, set: { uploads.changeConcurrency($0) })) {
                ForEach(DirectUploadConcurrency.allCases) { count in Text(count.label).tag(count) }
            }.disabled(uploads.isActive || uploads.preparing)
            Text("Four files is the default. Try eight for fast SSDs and connections, or one or two for a hard drive. Pause to change this setting, then Resume.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SearchShortcutSettings: View {
    @ObservedObject var controller: SpotlightPanelController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Search from anywhere", selection: Binding(get: { controller.shortcut }, set: { controller.changeShortcut($0) })) {
                ForEach(SearchShortcut.allCases) { Text($0.label).tag($0) }
            }
            if let error = controller.shortcutError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry shortcut") { controller.registerShortcut() }
            }
            Text("Search is always available from the menu bar and with Command–Shift–F in CloudDrive.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
