import Foundation

/// Upload work and Finder mounting are separate capabilities, never competing connection states.
struct DirectUploadStatusSummary: Equatable {
    var pending = 0
    var paused = 0
    var attention = 0
    var foreign = 0
    var active = false
    var preparing = false
    var recordsUnavailable = false
}

/// One conservative status contract shared by the dashboard and menu bar.
struct StatusPresentation: Equatable {
    enum Tone: Equatable { case normal, working, attention }
    let title: String
    let subtitle: String
    let symbol: String
    let tone: Tone

    init(mount: MountState, uploads: UploadState, busy: Bool, mounted: Bool,
         running: Bool, authorizationNeeded: Bool, queueAvailable: Bool,
         snapshot: UploadProgressSnapshot?, moves: FinderMoveStatus? = nil, moveStatusUnknown: Bool = false, direct: DirectUploadStatusSummary = .init()) {
        if mount == .blocked || (mount == .unmounted && !running) {
            self.init(title: "Finder browsing needs attention", subtitle: mount.text, symbol: "exclamationmark.triangle", tone: .attention)
        } else if authorizationNeeded {
            self.init(title: "Unlock your saved connection", subtitle: "Choose Load Saved Connection and respond to macOS if asked.", symbol: "lock", tone: .attention)
        } else if mount == .unmounted && running {
            if moveStatusUnknown {
                self.init(title: "Finder ejected — background status unavailable", subtitle: "Keep CloudDrive running. Retry status from Finder recovery.", symbol: "questionmark.circle", tone: .attention)
            } else if let moves, moves.hasRecoverableJobs || moves.hasFailedJobs {
                self.init(title: moves.title, subtitle: moves.displayMessage.isEmpty ? "Finder is ejected. Open Finder recovery to finish the move." : moves.displayMessage, symbol: "exclamationmark.triangle", tone: .attention)
            } else if let moves, moves.hasActiveJobs {
                self.init(title: "Finder ejected — finishing move", subtitle: "\(moves.title). Keep CloudDrive running until the move finishes.", symbol: "folder", tone: .working)
            } else if uploads == .outOfSpace {
                self.init(title: "Not enough local space", subtitle: "Finder is ejected. Preserve the cache and free space elsewhere to finish uploads.", symbol: "exclamationmark.triangle", tone: .attention)
            } else if case .failed = uploads {
                self.init(title: "Local cache needs attention", subtitle: uploads.text, symbol: "exclamationmark.triangle", tone: .attention)
            } else if !queueAvailable || snapshot == nil || uploads == .unknown {
                self.init(title: "Finder ejected — background status unavailable", subtitle: "Pending Finder data may remain. Keep CloudDrive running and retry status from Finder recovery.", symbol: "questionmark.circle", tone: .attention)
            } else if let snapshot, !snapshot.isEmpty {
                self.init(title: "Finder ejected — finishing uploads", subtitle: "\(snapshot.activeCount) uploading · \(snapshot.queuedCount) waiting. Keep CloudDrive running until uploads finish.", symbol: "arrow.up.circle", tone: .working)
            } else if uploads == .idle {
                self.init(title: "Finder ejected", subtitle: "No Finder uploads or moves waiting. Finishing eject automatically.", symbol: "externaldrive", tone: .normal)
            } else {
                self.init(title: "Finder ejected — background status unavailable", subtitle: "Waiting for consistent Finder upload details. Keep CloudDrive running.", symbol: "questionmark.circle", tone: .attention)
            }
        } else if busy || mount == .checking {
            self.init(title: mount == .checking ? "Checking Finder browsing…" : "Updating Finder browsing…", subtitle: "Keep CloudDrive running while this operation finishes.", symbol: "arrow.triangle.2.circlepath", tone: .working)
        } else if running && moveStatusUnknown {
            self.init(title: "Move status unavailable", subtitle: "Keep CloudDrive running and retry status before ejecting.", symbol: "questionmark.circle", tone: .attention)
        } else if let moves, running && (moves.hasActiveJobs || moves.hasRecoverableJobs || moves.hasFailedJobs) {
            self.init(title: moves.title, subtitle: moves.displayMessage.isEmpty ? "Keep CloudDrive running while the move finishes." : moves.displayMessage, symbol: moves.hasRecoverableJobs ? "exclamationmark.triangle" : "folder", tone: moves.hasRecoverableJobs || moves.hasFailedJobs ? .attention : .working)
        } else if running && uploads == .outOfSpace {
            self.init(title: "Not enough local space", subtitle: "Preserve the cache and free space elsewhere to finish uploads.", symbol: "exclamationmark.triangle", tone: .attention)
        } else if running, case .failed = uploads {
            self.init(title: "Local cache needs attention", subtitle: uploads.text, symbol: "exclamationmark.triangle", tone: .attention)
        } else if running && mounted && (!queueAvailable || snapshot == nil || uploads == .unknown) {
            self.init(title: "Finder upload status unavailable", subtitle: "Pending Finder data may remain. Retry status from Finder recovery.", symbol: "questionmark.circle", tone: .attention)
        } else if direct.recordsUnavailable {
            self.init(title: "Upload records unavailable", subtitle: "Open Transfers and review saved uploads to recover the records.", symbol: "exclamationmark.triangle", tone: .attention)
        } else if direct.active {
            self.init(title: "Uploading directly to R2", subtitle: "Finder browsing is off while these uploads run.", symbol: "arrow.up.circle", tone: .working)
        } else if direct.preparing {
            self.init(title: "Preparing direct uploads…", subtitle: "Reading file references. No local file copy is needed.", symbol: "arrow.up.circle", tone: .working)
        } else if direct.pending > 0 {
            if direct.foreign == direct.pending {
                self.init(title: "Uploads need their original connection", subtitle: "Restore the connection saved with these files to continue.", symbol: "exclamationmark.triangle", tone: .attention)
            } else if mounted || running {
                self.init(title: "Saved uploads are waiting", subtitle: "Open Transfers to review the saved queue. You can keep using Finder.", symbol: "arrow.up.circle", tone: .normal)
            } else if direct.attention > 0 {
                self.init(title: "Direct uploads need attention", subtitle: "Open Details to review the file, then resume. No Finder connection is needed.", symbol: "exclamationmark.triangle", tone: .attention)
            } else if direct.paused > 0 {
                self.init(title: "Direct uploads paused", subtitle: "Choose Resume to continue. Finder browsing is off until these uploads finish.", symbol: "pause.circle", tone: .normal)
            } else {
                self.init(title: "Saved uploads are waiting", subtitle: "Open Transfers to review and resume the saved queue.", symbol: "arrow.up.circle", tone: .normal)
            }
        } else if !running || !mounted || mount != .connected {
            self.init(title: "Drive disconnected", subtitle: "Connect CloudDrive to browse your files in Finder.", symbol: "externaldrive", tone: .normal)
        } else if !queueAvailable || snapshot == nil || uploads == .unknown {
            self.init(title: "Finder upload status unavailable", subtitle: "Pending Finder data may remain. Retry status from Finder recovery.", symbol: "questionmark.circle", tone: .attention)
        } else if let snapshot, !snapshot.isEmpty {
            let count = snapshot.rows.count
            self.init(title: snapshot.retryingCount > 0 ? "Finder uploads retrying" : "Uploading \(count) \(count == 1 ? "file" : "files") through Finder", subtitle: "\(snapshot.activeCount) uploading · \(snapshot.queuedCount) waiting", symbol: "arrow.up.circle", tone: .working)
        } else if uploads == .idle {
            self.init(title: "Drive connected", subtitle: "Open CloudDrive in Finder to browse and copy files.", symbol: "checkmark.circle", tone: .normal)
        } else {
            self.init(title: "Finder upload status unavailable", subtitle: "Waiting for consistent Finder upload details.", symbol: "questionmark.circle", tone: .attention)
        }
    }

    fileprivate init(title: String, subtitle: String, symbol: String, tone: Tone) {
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
        let engine = namespaceEngine
        if engine.ownsDestination {
            let shared = NamespaceTransferPresentation(enabled: engine.enabled, running: engine.running, mounted: engine.mounted,
                readOnly: engine.readOnly, busy: engine.busy, status: engine.status, error: engine.error, statusIsFresh: UploadFreshness.isFresh(engine.statusSampledAt, at: date))
            let tone: StatusPresentation.Tone = shared.tone == .attention ? .attention : (shared.tone == .working ? .working : .normal)
            let symbol = tone == .attention ? "exclamationmark.triangle" : (tone == .working ? "arrow.triangle.2.circlepath" : shared.tone == .published ? "checkmark.circle" : "externaldrive")
            return .init(title: shared.title, subtitle: shared.subtitle, symbol: symbol, tone: tone)
        }
        return StatusPresentation(mount: mountState, uploads: uploads, busy: busy, mounted: mounted, running: running, authorizationNeeded: keychainNeedsApproval, queueAvailable: activityAvailable && UploadFreshness.isFresh(uploadSampledAt, at: date), snapshot: uploadProgress, moves: UploadFreshness.isFresh(moveSampledAt, at: date) ? finderMoves : nil, moveStatusUnknown: movesExpected && !UploadFreshness.isFresh(moveSampledAt, at: date), direct: directUploads.statusSummary(destination: connection.fingerprint))
    }
    var needsSetup: Bool {
        !running && mountState == .disconnected && !keychainNeedsApproval && connection.endpoint.isEmpty
    }
}

enum UploadFreshness {
    static func isFresh(_ sampledAt: Date?, at date: Date, maximumAge: TimeInterval = 5) -> Bool {
        guard let sampledAt else { return false }
        let age = date.timeIntervalSince(sampledAt)
        return age >= 0 && age <= maximumAge
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
