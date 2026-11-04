import SwiftUI

struct DriveSettingsView: View {
    @ObservedObject var drive: Drive
    @State private var selectedUploadLimit: UploadLimit = .unlimited
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            transfers.tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            storage.tabItem { Label("Storage", systemImage: "internaldrive") }
            connection.tabItem { Label("Connection", systemImage: "network") }
            diagnostics.tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }.padding(20).frame(width: 580, height: 500)
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Upload speed").font(.headline)
            Picker("Upload limit", selection: $selectedUploadLimit) {
                ForEach(UploadLimit.allCases) { limit in Text(limit.label).tag(limit) }
            }.disabled(!canChangeUploadLimit)
            Button(drive.running ? "Apply upload limit" : "Save for next connection") {
                Task { await drive.changeUploadLimit(selectedUploadLimit) }
            }.disabled(!canChangeUploadLimit)
            metricRow("Saved upload limit", value: drive.uploadLimit.label)
            if drive.running {
                metricRow("Applied upload limit", value: drive.appliedUploadLimit?.label ?? "Unknown")
                if drive.appliedUploadLimit == nil {
                    Text("The worker’s applied limit has not been confirmed. A requested value is not shown as applied until readback succeeds.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("The saved limit will apply when the drive next connects.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Limits use Mbps (megabits per second). Transfer speed uses MB/s (megabytes per second): 8 Mbps is 1 MB/s. Downloads remain unlimited.").font(.callout).foregroundStyle(.secondary)
            Text("Waiting uploads retry automatically. Retry Now in Transfers schedules an eligible waiting item; it does not pause or cancel an active upload.").font(.callout).foregroundStyle(.secondary)
            OperationFeedback(drive: drive)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { selectedUploadLimit = drive.uploadLimit }
            .onChange(of: drive.uploadLimit) { _, value in selectedUploadLimit = value }
    }

    private var canChangeUploadLimit: Bool {
        !drive.busy && drive.mountState != .blocked && drive.mountState != .checking && (drive.running || drive.canConnect)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CloudDrive").font(.title2.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")").foregroundStyle(.secondary)
            LoginItemSettingsView()
            Text("Keep CloudDrive running while using the Finder drive. Closing a window leaves your drive connected. Eject before quitting to finish pending uploads.")
            Text("Use one actively writing Mac at a time. File version history, offline pins and encrypted storage are not available yet.").font(.callout).foregroundStyle(.secondary)
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
                Text(drive.status).font(.headline)
                Text(drive.uploadStatus)
                if !drive.detail.isEmpty { Text(drive.detail).font(.callout).textSelection(.enabled) }
                Button("Test Bucket with a 1 MB File") { Task { await drive.verifyBucket() } }.disabled(!drive.mounted || drive.busy)
                Text("The test creates a disposable 1 MiB file, downloads it independently and compares SHA-256. A pass applies to that fixture only.").font(.caption).foregroundStyle(.secondary)
                if !drive.verification.isEmpty { Label(drive.verification, systemImage: "checkmark.circle").font(.callout).textSelection(.enabled) }
                OperationFeedback(drive: drive)
                RecentActivityView(drive: drive)
                Text("Finder uses a loopback NFS server accessible to other processes on this Mac. No LAN listener is opened.").font(.caption).foregroundStyle(.secondary)
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
