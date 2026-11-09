import SwiftUI
import AppKit
import CloudDriveCore

/// Mount status and cloud durability have independent meanings. Missing, stale or
/// failed status must never turn an acknowledged local edit into a cloud-success claim.
struct NamespaceTransferPresentation: Equatable {
    enum Tone: Equatable { case neutral, working, attention, published }
    let title: String
    let subtitle: String
    let tone: Tone
    private(set) var uploadSpeed: String?
    var cloudCopyLabel: String { tone == .published ? "Confirmed in R2" : "Not yet confirmed" }
    static func valid(_ status: SyncEngineStatus) -> Bool {
        status.pending >= 0 && status.attention >= 0 && status.dirtyBytes >= 0 &&
        status.cleanCacheBytes >= 0 && status.pinnedBytes >= 0 && status.retainedCleanBytes >= 0 &&
        status.localRevision >= 0 && status.publishedRevision >= 0 && status.publishedRevision <= status.localRevision &&
        status.requestedPins >= 0 && status.completedPins >= 0 && status.completedPins <= status.requestedPins &&
        status.pinAttention >= 0 && status.pinRequestedBytes >= 0 && status.pinCompletedBytes >= 0 &&
        status.pinCompletedBytes <= status.pinRequestedBytes
    }
    init(enabled: Bool, running: Bool, mounted: Bool, readOnly: Bool, busy: Bool, status: SyncEngineStatus?, error: String, statusIsFresh: Bool = true) {
        if !error.isEmpty {
            title = "File management needs attention"; subtitle = error; tone = .attention
        } else if !enabled && !running {
            title = "File management is off"; subtitle = "Preview your connection in File management settings."; tone = .neutral
        } else if readOnly {
            title = "Read-only preview"; subtitle = "Changes are not enabled. Your original objects are preserved."; tone = .neutral
        } else if !enabled {
            title = "File management needs recovery"; subtitle = "Recover this connection before continuing file changes."; tone = .attention
        } else if busy {
            title = "Updating file management…"; subtitle = "Keep CloudDrive running while this operation finishes."; tone = .working
        } else if !running {
            title = "Finder is disconnected"; subtitle = "Reconnect to check pending changes and continue syncing."; tone = .neutral
        } else if !statusIsFresh {
            title = "Cloud status is unavailable"; subtitle = "Waiting for a fresh status update. Saved changes are retained."; tone = .attention
        } else if let status {
            let hasPendingUploads = status.pending > 0 || status.dirtyBytes > 0 || status.publishedRevision < status.localRevision
            if !Self.valid(status) {
                title = "Cloud status is unavailable"; subtitle = "The reported state could not be confirmed. Saved changes are retained."; tone = .attention
            } else if status.phase == "waitingForNetwork" {
                title = "Waiting for R2"; subtitle = "Your changes are saved on this Mac. Syncing will retry automatically."; tone = .working
            } else if status.attention > 0 || status.phase == "attention" || status.lastError != nil {
                title = "Some changes need attention"; subtitle = "Saved changes are retained. Resolve the problem, then Resume syncing."; tone = .attention
            } else if status.phase == "paused" {
                title = "Syncing is paused"; subtitle = "Saved changes and download progress are retained. Choose Resume syncing when ready."; tone = .neutral
            } else if status.phase == "pausing" {
                title = "Pausing after the current cloud step"; subtitle = "Accepted local changes remain saved."; tone = .working
            } else if hasPendingUploads || status.phase == "working" || status.phase == "pending" {
                title = mounted ? "Saved on this Mac — syncing to R2" : "Finder ejected — syncing changes"
                subtitle = "\(status.pending.formatted()) pending operations. Keep CloudDrive running until they finish."; tone = .working
                if let speed = status.uploadBytesPerSecond, hasPendingUploads || speed > 0 {
                    uploadSpeed = UploadMetricText.speed(speed)
                }
            } else if status.pinAttention > 0 {
                title = "Offline downloads need attention"; subtitle = "Some files are not yet available offline. Review storage space and retry."; tone = .attention
            } else if status.completedPins < status.requestedPins || status.pinCompletedBytes < status.pinRequestedBytes {
                title = "Downloading for offline use"; subtitle = "Keep CloudDrive running until your selected files are available offline."; tone = .working
            } else if status.phase != "idle" {
                title = "Cloud status is unavailable"; subtitle = "Retry status before assuming uploads are complete."; tone = .attention
            } else {
                title = "Changes are uploaded to R2"; subtitle = mounted ? "Finder browsing is connected." : "Finder is ejected. Cloud work is complete."; tone = .published
            }
        } else {
            title = "Cloud status is unavailable"; subtitle = "Saved changes and recovery records are retained. Retry the connection before assuming uploads are complete."; tone = .attention
        }
    }
}

struct NamespaceTransfersView: View {
    @ObservedObject var engine: NamespaceDriveController
    var showsUploadButton = true
    @State private var showCompleted = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in content(at: max(context.date, Date())) }
    }
    private func content(at date: Date) -> some View {
        let presentation = NamespaceTransferPresentation(enabled: engine.enabled, running: engine.running, mounted: engine.mounted,
            readOnly: engine.readOnly, busy: engine.busy, status: engine.status, error: engine.error, statusIsFresh: UploadFreshness.isFresh(engine.statusSampledAt, at: date))
        return VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: symbol(presentation.tone)).font(.headline)
                .foregroundStyle(presentation.tone == .attention ? Color.orange : Color.primary)
            Text(presentation.subtitle).font(.callout).foregroundStyle(.secondary)
            if let speed = presentation.uploadSpeed { metric("Upload speed", speed) }
            if engine.running { UploadSpeedHistoryView(history: engine.speedHistory) }
            if let status = engine.status {
                metric("Pending operations", status.pending.formatted())
                metric("Need attention", status.attention.formatted())
                metric("Local save", NamespaceTransferPresentation.valid(status) ? "Accepted changes are saved locally" : "Status unavailable")
                metric("Cloud copy", presentation.cloudCopyLabel)
                Divider()
                metric("Pending local data", size(status.dirtyBytes))
                metric("Recent-read cache", size(status.cleanCacheBytes))
                metric("Kept downloaded", size(status.pinnedBytes))
                if status.retainedCleanBytes > 0 { metric("Uploaded data still in use", size(status.retainedCleanBytes)) }
                if status.requestedPins > 0 {
                    metric("Offline downloads", "\(status.completedPins) of \(status.requestedPins) complete")
                    if status.pinRequestedBytes > 0 {
                        ProgressView(value: min(1, max(0, Double(status.pinCompletedBytes) / Double(status.pinRequestedBytes))))
                    }
                }
                Text("Local save and upload completion are separate. Recent-read cache can be released; pending data stays protected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if showsUploadButton {
                    Button("Upload files or folders…") { chooseUploads() }
                        .disabled(!engine.enabled || engine.readOnly || !engine.running || engine.busy)
                }
                if engine.running && !engine.readOnly {
                    if engine.status?.phase == "paused" {
                        Button("Resume syncing") { Task { await engine.resume() } }.disabled(engine.busy)
                    } else {
                        Button("Pause syncing") { Task { await engine.pause() } }.disabled(engine.busy || engine.status?.phase == "pausing")
                    }
                } else if engine.hasSession {
                    Button("Recover connection") { Task { await engine.recover() } }.disabled(engine.busy)
                }
            }
            if showsUploadButton {
                Divider()
                HStack {
                    Text("Activity").font(.headline)
                    Spacer()
                    Toggle("Show completed", isOn: $showCompleted).toggleStyle(.checkbox)
                }
                let rows = engine.activity.filter { showCompleted || $0.state != .complete }
                let activityIsFresh = UploadFreshness.isFresh(engine.activitySampledAt, at: date, maximumAge: 12)
                if rows.isEmpty {
                    Text(activityIsFresh ? "No operations in this view." : "Activity is unavailable.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(rows) { item in activityRow(item, fresh: activityIsFresh) }
                        }
                    }.frame(maxHeight: 320)
                    Text("Showing up to 200 recent operations. Pending work appears first. Completed operations are retained in the local records.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if engine.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating file management") }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func activityRow(_ item: NamespaceActivityItem, fresh: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.state == .attention ? "exclamationmark.triangle" : item.state == .complete ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                .foregroundStyle(item.state == .attention ? Color.orange : Color.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(NamespaceActivityPresentation.label(item, fresh: fresh)).font(.caption).foregroundStyle(.secondary)
                AvailabilityBadge(value: engine.activityAvailability[item.nodeID].flatMap(CatalogAvailability.init(rawValue:)) ?? .unknown,
                    checkedAt: fresh ? engine.activitySampledAt : nil)
                if let path = item.path { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if let failure = item.failureCode { Text("Needs attention: " + failure).font(.caption).textSelection(.enabled) }
            }
            Spacer(minLength: 8)
            if let bytes = item.size { Text(size(bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }.accessibilityElement(children: .combine)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(minLength: 12); Text(value).foregroundStyle(.secondary).monospacedDigit() }
            .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func symbol(_ tone: NamespaceTransferPresentation.Tone) -> String {
        switch tone { case .neutral: return "externaldrive"; case .working: return "arrow.triangle.2.circlepath"; case .attention: return "exclamationmark.triangle"; case .published: return "checkmark.circle" }
    }
    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.title = "Choose files or folders to upload"
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await engine.enqueue(urls) }
    }
}

enum NamespaceActivityPresentation {
    static func label(_ item: NamespaceActivityItem, fresh: Bool) -> String {
        let action: String
        switch item.kind {
        case .create: action = "Create"; case .rename: action = "Move or rename"; case .remove: action = "Delete"
        case .write: action = "Upload"; case .pin: action = "Offline availability"; case .metadata: action = "File information"
        }
        guard fresh else { return action + " · Status unavailable" }
        switch item.state {
        case .pending: return action + " · Waiting"
        case .running: return action + " · In progress"
        case .attention: return action + " · Needs attention"
        case .complete: return action + (item.localOnly ? " · Saved locally" : " · Complete")
        }
    }
}
