import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var drive: Drive
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 23, weight: .light))
                        .frame(width: 48, height: 48)
                        .background(LinearGradient(colors: [.primary.opacity(0.09), .primary.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.1)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CloudDrive").font(.system(size: 19, weight: .semibold)).tracking(-0.5)
                        Text("R2 DRIVE").font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1.5).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !drive.needsSetup {
                        Button { drive.openDrive() } label: {
                            HStack(spacing: 7) {
                                Text("Open in Finder")
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            }.padding(.horizontal, 5).padding(.vertical, 4)
                        }.disabled(!drive.mounted)
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
                    StorageSummary(drive: drive)
                    Divider()
                    DashboardActions(drive: drive)
                }
            }
            .padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .font(.system(size: 12))
        .buttonStyle(.bordered).controlSize(.small).tint(.primary)
        .background(.regularMaterial)
        .frame(minWidth: 460, minHeight: 350)
    }
}

struct StatusCard: View {
    @ObservedObject var drive: Drive
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            // Evaluate at render time: samples may arrive between timeline ticks.
            let status = drive.presentation(at: Date())
            VStack(alignment: .leading, spacing: 8) {
                Label(status.title, systemImage: status.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(status.tone == .attention ? Color.orange : Color.primary)
                Text(status.subtitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Storage", systemImage: "cloud").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if drive.running && drive.automaticSpaceSaving {
                    Text("AUTO").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                        .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel("Automatic space saving is on")
                }
            }
            Text(drive.storagePolicyText).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            Text("Uncached files need internet. Uploads and active reads use temporary local space.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)
        }
    }
}

struct DashboardActions: View {
    @ObservedObject var drive: Drive
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 18) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
            Button { openWindow(id: "recovery") } label: { Label("Recovery", systemImage: "arrow.counterclockwise") }
            Spacer()
            Button { Task { await drive.eject() } } label: { Label("Eject", systemImage: "eject") }
                .disabled(!drive.canEject)
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
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
