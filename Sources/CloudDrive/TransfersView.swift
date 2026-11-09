import SwiftUI

struct TransfersView: View {
    @ObservedObject var drive: Drive
    @State private var filter = TransferFilter.all
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
        let renderDate = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FinderMovesView(drive: drive)
                Text(drive.presentation(at: renderDate).title).font(.headline)
                if let issue = drive.uploadIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.callout) }
                if drive.running && drive.activityAvailable && UploadFreshness.isFresh(drive.uploadSampledAt, at: renderDate), let snapshot = drive.uploadProgress {
                    if snapshot.isEmpty {
                        Text("No Finder uploads waiting. Copy files into CloudDrive in Finder to upload them.").foregroundStyle(.secondary)
                    } else {
                        Picker("Show uploads", selection: $filter) {
                            ForEach(TransferFilter.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        let ids = Set(drive.activity.filter(filter.includes).map(\.id))
                        let rows = filter == .all ? snapshot.rows : snapshot.rows.filter { ids.contains($0.id) }
                        if rows.isEmpty {
                            Text(drive.activity.count < snapshot.rows.count ? "No matching uploads among the available queue details. Other items may match this filter." : "No \(filter.rawValue.lowercased()) uploads in the current queue.").foregroundStyle(.secondary)
                        }
                        if filter != .all && drive.activity.count < snapshot.rows.count {
                            Text("Filters cover the first \(drive.activity.count) queue details. \(snapshot.rows.count - drive.activity.count) additional items are visible under All.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(rows.prefix(50))) { row in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(row.name).font(.callout.weight(.medium)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Text(row.label)
                                    Spacer()
                                    if let bytes = row.bytes, let size = row.size { Text("\(formatted(bytes)) of \(formatted(size))").monospacedDigit() }
                                }.font(.caption).foregroundStyle(.secondary)
                                if let progress = row.progress {
                                    ProgressView(value: progress).accessibilityLabel("\(row.name) upload progress")
                                } else { Text("Progress unavailable").font(.caption).foregroundStyle(.secondary) }
                                Text("\(UploadMetricText.speed(row.speed)) · \(UploadMetricText.remaining(row.eta))").font(.caption).foregroundStyle(.secondary)
                                if let item = drive.activity.first(where: { $0.id == row.id && $0.name == row.name && $0.size == row.size }),
                                   item.tries > 1 && !item.uploading, let sessionID = drive.activitySessionID {
                                    Button("Retry Now") { Task { await drive.retryUpload(item, sessionID: sessionID) } }
                                        .disabled(drive.busy || drive.mountState == .blocked || drive.mountState == .checking)
                                        .accessibilityLabel("Retry upload \(row.name) now")
                                        .help("Schedules this waiting upload. It does not pause active transfers or confirm completion.")
                                }
                            }.accessibilityElement(children: .contain)
                            Divider()
                        }
                        if rows.count > 50 {
                            Text("Showing the first 50 of \(rows.count) matching uploads. \(rows.count - 50) more remain in the queue.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("This list covers the outstanding queue. Disappearing items are not presented as verified completion receipts.").font(.caption).foregroundStyle(.secondary)
                        Text("Retry Now schedules a waiting retry. It does not pause or cancel active uploads.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(drive.running ? "Waiting for current transfer details." : "Connect CloudDrive to see transfer progress.").foregroundStyle(.secondary)
                }
                OperationFeedback(drive: drive)
                if !drive.diagnostics.isEmpty {
                    DisclosureGroup("Diagnostic activity") { RecentActivityView(drive: drive) }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 520, minHeight: 420)
        }
    }
    private func formatted(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct RecentActivityView: View {
    @ObservedObject var drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent drive activity").font(.headline)
            Text("Up to 50 events from this app session. This is diagnostic activity, not a file completion history.").font(.caption).foregroundStyle(.secondary)
            if drive.diagnostics.isEmpty { Text("No recent events.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(drive.diagnostics.suffix(50).reversed())) { event in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(event.time, style: .time).monospacedDigit(); Text(event.category) }.font(.caption.weight(.medium))
                    Text(event.outcome).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
