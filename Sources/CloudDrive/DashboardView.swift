import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var drive: Drive
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CloudDrive").font(.title3.weight(.semibold))
                        Text("Cloudflare R2").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    if !drive.needsSetup {
                        Button { drive.openDrive() } label: {
                            Text("Open in Finder").frame(minHeight: 22)
                        }
                            .modifier(DriveButtonAppearance(prominent: true))
                            .controlSize(.large)
                            .keyboardShortcut("o", modifiers: .command)
                            .help("Open in Finder (⌘O)")
                            .disabled(!drive.mounted)
                    }
                }
                if drive.needsSetup {
                    SetupView(drive: drive)
                } else {
                    StatusCard(drive: drive)
                    if drive.running && drive.activityAvailable, let snapshot = drive.uploadProgress, !snapshot.isEmpty {
                        CompactTransfers(snapshot: snapshot, sampledAt: drive.uploadSampledAt)
                    }
                    if drive.mountState == .blocked || drive.mountState == .unmounted || drive.keychainNeedsApproval {
                        RecoveryActions(drive: drive)
                    }
                    if drive.busy || drive.lastOperationFailed || drive.keychainNeedsApproval || drive.mountState == .blocked || drive.mountState == .unmounted {
                        OperationFeedback(drive: drive)
                    }
                    if !drive.running && !drive.keychainNeedsApproval {
                        Button("Connect") { Task { await drive.start() } }.disabled(!drive.canConnect)
                    }
                    StorageSummary(drive: drive, compact: true)
                    Divider()
                    DashboardActions(drive: drive)
                }
            }
            .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .font(.body)
        .modifier(DriveButtonAppearance()).controlSize(.regular)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 440, minHeight: 280)
    }
}

struct StatusCard: View {
    @ObservedObject var drive: Drive
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            // Evaluate at render time: samples may arrive between timeline ticks.
            let status = drive.presentation(at: Date())
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(status.tone == .attention ? Color.orange : Color.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.title == "Connected · No uploads waiting" ? "Connected" : status.title)
                        .font(.headline)
                    Text(status.title == "Connected · No uploads waiting" ? "No uploads waiting" : status.subtitle)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct OperationFeedback: View {
    @ObservedObject var drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !drive.operationResult.isEmpty { Text(drive.operationResult).font(.callout).textSelection(.enabled) }
            if drive.busy {
                HStack {
                    ProgressView().controlSize(.small).accessibilityLabel("Drive operation in progress")
                    Button("Cancel operation") { drive.cancelOperation() }
                }
            }
        }
    }
}

struct StorageSummary: View {
    @ObservedObject var drive: Drive
    var compact = false
    @State private var detailsExpanded = false

    var body: some View {
        if compact {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                details.padding(.top, 8)
            } label: {
                HStack {
                    Text("Local storage")
                    Spacer()
                    Text(drive.running && drive.automaticSpaceSaving ? "Automatic" : "Details")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local storage").font(.headline)
                details
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(drive.storagePolicyText)
            Text("Uncached files need internet. Uploads and active reads use temporary local space.")
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct DashboardActions: View {
    @ObservedObject var drive: Drive
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 4) { actions }
            } else {
                actions
            }
        }
        .modifier(DriveButtonAppearance())
        .controlSize(.large)
        .font(.body)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            SettingsLink { Label("Settings", systemImage: "gearshape").frame(minHeight: 18) }
            Button { openWindow(id: "recovery") } label: { Label("Recovery", systemImage: "arrow.counterclockwise").frame(minHeight: 18) }
            Spacer()
            Button { Task { await drive.eject() } } label: { Label("Eject", systemImage: "eject").frame(minHeight: 18) }
                .disabled(!drive.canEject)
        }
    }
}

struct CompactTransfers: View {
    let snapshot: UploadProgressSnapshot
    let sampledAt: Date?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
        VStack(alignment: .leading, spacing: 8) {
            if UploadFreshness.isFresh(sampledAt, at: Date()) {
            HStack {
                Label("\(snapshot.rows.count) current uploads", systemImage: "arrow.up.circle")
                Spacer()
                Text(UploadMetricText.speed(snapshot.speed)).monospacedDigit()
            }.font(.callout)
            if let progress = snapshot.progress { ProgressView(value: progress).accessibilityLabel("Outstanding upload queue progress") }
            if let bytes = snapshot.completedBytes, let total = snapshot.totalBytes {
                Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) in current queue").font(.caption).foregroundStyle(.secondary)
            }
            Text(UploadMetricText.remaining(snapshot.eta)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Upload status unavailable").font(.callout)
            }
            Button("Show transfers") { openWindow(id: "transfers") }
        }
        }
    }
}

/// Native Liquid Glass on supported systems, with the existing macOS 14–25 appearance.
private struct DriveButtonAppearance: ViewModifier {
    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
