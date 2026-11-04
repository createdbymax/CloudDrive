import SwiftUI

/// Transfer figures describe only the current upload queue. Cache usage and
/// rclone's lifetime transfer counters are deliberately not presented as progress.
struct UploadProgressPanel: View {
    let snapshot: UploadProgressSnapshot?
    let isConnected: Bool
    let queueAvailable: Bool
    var issue: String? = nil

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Uploads", systemImage: "arrow.up.circle")
                        .font(.headline)
                    Spacer()
                    if isConnected, queueAvailable, let snapshot, !snapshot.isEmpty {
                        Text(counts(snapshot))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Upload needs attention. \(issue)")
                }
                if !isConnected {
                    message("Connect the drive to see upload progress.")
                } else if !queueAvailable {
                    message("Upload activity is unavailable. Previous speed and progress are not shown.")
                } else if let snapshot {
                    if snapshot.isEmpty {
                        Label(issue == nil ? "No uploads waiting" : "No queued items reported", systemImage: issue == nil ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text(issue == nil ? "An idle queue does not independently verify your cloud files." : "An empty queue does not mean the reported problem is resolved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        summary(snapshot)
                        Divider()
                        ForEach(Array(snapshot.rows.prefix(50)), id: \.id) { row in
                            fileRow(row)
                        }
                        if snapshot.rows.count > 50 {
                            Text("\(snapshot.rows.count - 50) more files in the upload queue")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Totals cover files currently in the queue and can change as files finish. Local cache size is separate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    message("Waiting for live transfer details…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Upload progress")
    }

    @ViewBuilder private func summary(_ snapshot: UploadProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Current uploads")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let progress = snapshot.progress {
                    Text(percentage(progress))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .accessibilityLabel("Overall upload progress \(percentage(progress))")
                }
            }
            if let progress = snapshot.progress {
                ProgressView(value: progress, total: 1)
                    .accessibilityLabel("Current upload queue progress")
                    .accessibilityValue(percentage(progress))
            }
            Text(transferred(snapshot.completedBytes, total: snapshot.totalBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                metric("Upload speed", value: speed(snapshot.speed), accessibility: "Upload speed")
                metric("Time remaining", value: remaining(snapshot.eta), accessibility: "Estimated time remaining")
                Spacer(minLength: 0)
            }
            if snapshot.progress == nil {
                Text("Overall progress is unavailable until active transfers report their sizes and transferred bytes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fileRow(_ row: UploadProgressRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.name)
                Spacer(minLength: 8)
                Text(row.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let progress = row.progress {
                ProgressView(value: progress, total: 1)
                    .accessibilityLabel("\(row.name) upload progress")
                    .accessibilityValue(percentage(progress))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(transferred(row.bytes, total: row.size))
                Spacer(minLength: 8)
                if let progress = row.progress {
                    Text(percentage(progress))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if row.speed != nil || row.eta != nil {
                Text("\(speed(row.speed)) · \(row.eta == nil ? "Time remaining unavailable" : remaining(row.eta) + " remaining")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, value: String, accessibility: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityValue(value)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func counts(_ snapshot: UploadProgressSnapshot) -> String {
        var result = "\(snapshot.activeCount) uploading · \(snapshot.queuedCount) queued"
        if snapshot.retryingCount > 0 { result += " · \(snapshot.retryingCount) retrying" }
        return result
    }

    private func transferred(_ bytes: Int64?, total: Int64?) -> String {
        switch (bytes, total) {
        case (.some(let bytes), .some(let total)): return "\(size(bytes)) of \(size(total))"
        case (.some(let bytes), .none): return "\(size(bytes)) transferred · total unavailable"
        case (.none, .some(let total)): return "\(size(total)) total · transferred size unavailable"
        case (.none, .none): return "Transferred size unavailable"
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func speed(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return (value / 1_000_000).formatted(.number.precision(.fractionLength(1...2))) + " MB/s"
    }

    private func percentage(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return (min(max(value, 0), 1) * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func remaining(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Unavailable" }
        if seconds < 1 { return "Under 1 sec" }
        if seconds >= 86_400 { return "Over 1 day" }
        let value = Int(seconds.rounded(.up))
        if value >= 3600 { return "\(value / 3600) hr \((value % 3600) / 60) min" }
        if value >= 60 { return "\(value / 60) min \(value % 60) sec" }
        return "\(value) sec"
    }
}
