import Foundation

/// One conservative status contract shared by the dashboard and menu bar.
struct StatusPresentation: Equatable {
    enum Tone: Equatable { case normal, working, attention }
    let title: String
    let subtitle: String
    let symbol: String
    let tone: Tone

    init(mount: MountState, uploads: UploadState, busy: Bool, mounted: Bool,
         running: Bool, authorizationNeeded: Bool, queueAvailable: Bool,
         snapshot: UploadProgressSnapshot?) {
        if mount == .blocked || mount == .unmounted {
            self.init(title: "Drive needs attention", subtitle: mount.text, symbol: "exclamationmark.triangle", tone: .attention)
        } else if authorizationNeeded {
            self.init(title: "Unlock your saved connection", subtitle: "Choose Load Saved Connection and respond to macOS if asked.", symbol: "lock", tone: .attention)
        } else if busy || mount == .checking {
            self.init(title: mount == .checking ? "Checking your drive…" : "Working on your drive…", subtitle: "Keep CloudDrive running while this operation finishes.", symbol: "arrow.triangle.2.circlepath", tone: .working)
        } else if !running || !mounted || mount != .connected {
            self.init(title: "Your R2 drive is disconnected", subtitle: "Connect to browse your files in Finder.", symbol: "externaldrive", tone: .normal)
        } else if uploads == .outOfSpace {
            self.init(title: "Not enough local space", subtitle: "Preserve the cache and free space elsewhere to finish uploads.", symbol: "exclamationmark.triangle", tone: .attention)
        } else if case .failed = uploads {
            self.init(title: "Local cache needs attention", subtitle: uploads.text, symbol: "exclamationmark.triangle", tone: .attention)
        } else if !queueAvailable || snapshot == nil || uploads == .unknown {
            self.init(title: "Upload status unavailable", subtitle: "Pending local data may remain. Retry status from Recovery.", symbol: "questionmark.circle", tone: .attention)
        } else if let snapshot, !snapshot.isEmpty {
            let count = snapshot.rows.count
            self.init(title: snapshot.retryingCount > 0 ? "Uploads retrying" : "Uploading \(count) \(count == 1 ? "file" : "files")", subtitle: "\(snapshot.activeCount) uploading · \(snapshot.queuedCount) waiting", symbol: "arrow.up.circle", tone: .working)
        } else if uploads == .idle {
            self.init(title: "Connected · No uploads waiting", subtitle: "Finder copies stage on this Mac first. Uploads start after each file finishes copying.", symbol: "checkmark.circle", tone: .normal)
        } else {
            self.init(title: "Upload status unavailable", subtitle: "Waiting for consistent upload details.", symbol: "questionmark.circle", tone: .attention)
        }
    }

    private init(title: String, subtitle: String, symbol: String, tone: Tone) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tone = tone
    }
}

enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", queued = "Queued", retrying = "Retrying"
    var id: Self { self }
    func includes(_ item: UploadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return item.uploading
        case .queued: return !item.uploading
        case .retrying: return item.tries > 1
        }
    }
}

@MainActor extension Drive {
    var presentation: StatusPresentation { presentation(at: Date()) }
    func presentation(at date: Date) -> StatusPresentation {
        StatusPresentation(mount: mountState, uploads: uploads, busy: busy, mounted: mounted, running: running, authorizationNeeded: keychainNeedsApproval, queueAvailable: activityAvailable && UploadFreshness.isFresh(uploadSampledAt, at: date), snapshot: uploadProgress)
    }
    var needsSetup: Bool {
        !running && mountState == .disconnected && !keychainNeedsApproval && connection.endpoint.isEmpty
    }
}

enum UploadFreshness {
    static func isFresh(_ sampledAt: Date?, at date: Date) -> Bool {
        guard let sampledAt else { return false }
        let age = date.timeIntervalSince(sampledAt)
        return age >= 0 && age <= 5
    }
}

enum UploadMetricText {
    static func speed(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Speed unavailable" }
        return (value / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " MB/s"
    }
    static func remaining(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Time remaining unavailable" }
        if seconds < 1 { return "Under 1 sec remaining" }
        if seconds >= 86_400 { return "Over 1 day remaining" }
        let count = Int(seconds.rounded(.up))
        if count >= 3600 { return "About \(count / 3600) hr \((count % 3600) / 60) min remaining" }
        if count >= 60 { return "About \(count / 60) min remaining" }
        return "About \(count) sec remaining"
    }
}
