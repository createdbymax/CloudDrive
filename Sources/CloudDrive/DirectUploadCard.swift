import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Presentation follows persisted/verified queue state, never the animation's visual progress.
struct DirectUploadRowPresentation {
    let job: DirectUploadJob
    let active: Bool
    var showsProgress: Bool { job.status == .uploading || job.status == .paused || job.status == .checking }
    var showsCompletion: Bool { job.status == .uploaded }
    var status: String {
        switch job.status {
        case .uploading: return active ? "Uploading" : "Paused"
        case .paused: return "Paused"
        case .checking: return active ? "Verifying" : "Verification pending"
        default: return job.status.label
        }
    }
    var symbol: String {
        let type = UTType(filenameExtension: URL(fileURLWithPath: job.sourcePath).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc.text"
    }
    func canCancel(destination: String, canDirectUpload: Bool, busy: Bool) -> Bool {
        !job.terminal && job.destination == destination && !busy &&
        (canDirectUpload || job.uploadID == nil && (job.phase == .queued || job.phase == .initiating))
    }
    func canRetry(destination: String, canDirectUpload: Bool, busy: Bool) -> Bool {
        !job.terminal && job.status != .cancelling && job.destination == destination && canDirectUpload && !busy
    }
}

/// Each slot advances independently; completing the first file never slides the other files up.
enum DirectUploadSlots {
    static func select(retaining ids: [UUID], metrics: DirectUploadQueueMetrics, limit: Int = 3) -> [UUID] {
        var reserved = Set(ids)
        var result: [UUID] = []
        for id in ids.prefix(limit) {
            guard let job = metrics.jobsByID[id] else { reserved.remove(id); continue }
            if job.terminal, let next = metrics.orderedJobs.prefix(metrics.pending).first(where: { !reserved.contains($0.id) }) {
                result.append(next.id); reserved.insert(next.id); reserved.remove(id)
            } else { result.append(id) }
        }
        for job in metrics.orderedJobs {
            if result.count == limit { break }
            if !result.contains(job.id) { result.append(job.id) }
        }
        return result
    }
}

enum DirectUploadFilter: String, CaseIterable, Identifiable {
    case queue = "In progress", attention = "Needs attention", completed = "Completed"
    var id: String { rawValue }
    func jobs(in metrics: DirectUploadQueueMetrics) -> [DirectUploadJob] {
        switch self {
        case .queue: return metrics.inProgressJobs
        case .attention: return metrics.attentionJobs
        case .completed: return metrics.completedJobs
        }
    }
}

struct DirectUploadCard: View {
    @ObservedObject var drive: Drive
    @ObservedObject var uploads: DirectUploadController
    var expanded = false
    var workspace = false
    var filter: Binding<DirectUploadFilter>? = nil
    var showDetails: (() -> Void)? = nil
    @State private var localFilter = DirectUploadFilter.queue
    private var filterBinding: Binding<DirectUploadFilter> { filter ?? $localFilter }
    private var listJobs: [DirectUploadJob] { workspace ? filterBinding.wrappedValue.jobs(in: uploads.metrics) : orderedJobs }
    @State private var page = 0
    @State private var selectedJob: UUID?
    @State private var compactSlots: [UUID] = []
    private var pending: Int { uploads.metrics.pending }
    private var attention: Int { uploads.metrics.attention }
    private var orderedJobs: [DirectUploadJob] { uploads.metrics.orderedJobs }
    private var visibleJobs: [DirectUploadJob] {
        if expanded { return Array(listJobs.dropFirst(page * 100).prefix(100)) }
        let ids = compactSlots.isEmpty ? DirectUploadSlots.select(retaining: [], metrics: uploads.metrics) : compactSlots
        return ids.compactMap { uploads.metrics.jobsByID[$0] }
    }
    private func updateSlots() {
        guard !expanded else { return }
        let next = DirectUploadSlots.select(retaining: compactSlots, metrics: uploads.metrics)
        if next != compactSlots { compactSlots = next }
    }
    private var foreignJobs: Int { uploads.metrics.foreignJobs(destination: drive.connection.fingerprint) }
    private var title: String {
        if uploads.preparing { return "Preparing files…" }
        if uploads.isActive { return uploads.jobs.contains(where: { $0.status == .checking }) ? "Verifying uploads…" : "Uploading files…" }
        if attention > 0 { return "\(attention) file\(attention == 1 ? " needs" : "s need") attention" }
        if pending > 0 { return "\(pending) file\(pending == 1 ? "" : "s") \(uploads.completedBytes > 0 ? "paused" : "queued")" }
        if uploads.jobs.isEmpty { return "Direct uploads" }
        return uploads.metrics.allCancelled ? "Uploads cancelled" : "Uploads finished"
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private var transferSummary: String {
        var text = "\(bytes(uploads.completedBytes)) of \(bytes(uploads.totalBytes))"
        if uploads.isActive, uploads.speed > 0 { text += " · " + UploadMetricText.speed(uploads.speed) }
        if let eta = uploads.eta { text += " · " + UploadMetricText.remaining(eta) }
        return text
    }

    var body: some View {
        Group {
            if workspace {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        cardHeading
                        if !uploads.jobs.isEmpty { transferProgress; queueControls }
                        recoveryFeedback
                    }.padding(18).modifier(UploadGlassSurface())
                    Picker("Show uploads", selection: filterBinding) {
                        ForEach(DirectUploadFilter.allCases) { item in
                            Text(item.rawValue + " (\(item.jobs(in: uploads.metrics).count))").tag(item)
                        }
                    }.pickerStyle(.segmented)
                    if listJobs.isEmpty { emptyList }
                    else { fileList; pagination }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    cardHeading
                    if !uploads.jobs.isEmpty {
                        transferProgress
                        if expanded || pending > 0 { fileList; pagination }
                        queueControls
                    }
                    recoveryFeedback
                }.padding(18).modifier(UploadGlassSurface())
            }
        }
        .transaction { $0.animation = nil }
        .onAppear { updateSlots() }
        .onChange(of: uploads.queueRevision) { _, _ in updateSlots(); clampPage() }
        .onChange(of: filterBinding.wrappedValue) { _, _ in page = 0; selectedJob = nil }
        .accessibilityElement(children: .contain).accessibilityLabel("Direct uploads")
    }
    private var cardHeading: some View {
        HStack {
            Text("Saved uploads").font(.headline)
            Spacer(minLength: 8)
            options
        }
    }
    private var transferProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium)).accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                Text(uploads.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(transferSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(2).frame(height: 30, alignment: .topLeading)
            UploadConfirmedProgress(value: uploads.progress, showsPercentage: false)
                .frame(height: 4).padding(.top, 3).accessibilityLabel("Confirmed upload progress")
        }
    }
    private var fileList: some View {
        LazyVStack(spacing: 6) {
            ForEach(Array(visibleJobs.enumerated()), id: \.offset) { _, job in
                if expanded || !job.terminal {
                    VStack(alignment: .leading, spacing: 8) {
                        uploadRow(job)
                        if selectedJob == job.id { fileDetails(job).padding(.horizontal, 10).padding(.bottom, 10) }
                    }
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.045)) }
                } else { Color.clear.frame(height: 62).accessibilityHidden(true) }
            }
        }
    }
    @ViewBuilder private var pagination: some View {
        if expanded && listJobs.count > 100 {
            HStack {
                Button("Previous") { page -= 1 }.disabled(page == 0)
                Spacer()
                Text("Page \(page + 1) of \((listJobs.count + 99) / 100)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Next") { page += 1 }.disabled((page + 1) * 100 >= listJobs.count)
            }.modifier(UploadButtonAppearance())
        }
    }
    private func clampPage() { page = min(page, max(0, (listJobs.count - 1) / 100)) }
    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(filterBinding.wrappedValue == .attention ? "No uploads need attention" : filterBinding.wrappedValue == .completed ? "No completed uploads yet" : "No files waiting to upload")
                .font(.headline)
            if filterBinding.wrappedValue == .queue && uploads.metrics.attention > 0 {
                Button("Review uploads needing attention") { filterBinding.wrappedValue = .attention }
            } else {
                Text(filterBinding.wrappedValue == .completed ? "Verified uploads appear here when they finish." : "Use Finder to copy new files to the drive.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uploadRow(_ job: DirectUploadJob) -> some View {
        let state = DirectUploadRowPresentation(job: job, active: uploads.isActive)
        let busy = uploads.isActive || uploads.preparing || uploads.needsRecordsRecovery
        return HStack(spacing: 10) {
            Image(systemName: state.symbol).font(.system(size: 16)).foregroundStyle(.secondary)
                .frame(width: 26, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).help(job.sourcePath)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(bytes(job.source.size)) · \(state.status)" + (job.status == .uploading && uploads.isActive ? " \(Int((job.progress * 100).rounded()))%" : ""))
                        .font(.system(size: 11)).foregroundStyle(job.status == .attention ? Color.orange : Color.secondary)
                        .lineLimit(1).monospacedDigit()
                    UploadConfirmedProgress(value: job.progress, showsPercentage: false)
                        .id(job.id) // A new file starts with its own native bar, not the prior slot's fill.
                        .frame(height: 3).opacity(state.showsProgress ? 1 : 0)
                }.frame(height: 23, alignment: .top)
            }.frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                if state.showsCompletion { UploadCompletionCheck().id(job.id) }
                else if job.status == .attention {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityLabel("Needs attention")
                } else if job.status == .checking && uploads.isActive {
                    ProgressView().controlSize(.mini).accessibilityLabel("Verifying upload")
                }
            }.frame(width: 18, height: 26)
            ZStack {
                if state.canRetry(destination: drive.connection.fingerprint, canDirectUpload: drive.canDirectUpload, busy: busy) {
                    Button { uploads.resume(connection: drive.connection, bytesPerSecond: drive.uploadLimit.bytesPerSecond, jobID: job.id) } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 26)
                    }.buttonStyle(UploadIconButtonStyle()).help("Resume this file")
                        .accessibilityLabel("Resume upload \(job.name)")
                }
            }.frame(width: 24, height: 26)
            Menu {
                Button(selectedJob == job.id ? "Hide file details" : "Show file details") { selectedJob = selectedJob == job.id ? nil : job.id }
                if !job.terminal {
                    if uploads.isActive { Button("Pause uploads") { uploads.pause() } }
                    Button("Cancel upload", role: .destructive) { uploads.cancel(job.id, connection: drive.connection) }
                        .disabled(!state.canCancel(destination: drive.connection.fingerprint, canDirectUpload: drive.canDirectUpload, busy: busy))
                    if job.uploadID != nil { Button("Check expiration…") { confirmRestart(job) }.disabled(busy || !drive.canDirectUpload || job.destination != drive.connection.fingerprint) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(job.name)")
            ZStack {
            if job.terminal {
                Button { uploads.clearFinished(job.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 26)
                }.buttonStyle(UploadIconButtonStyle()).disabled(busy)
                    .help("Remove from upload history. The cloud file and original are kept.")
                    .accessibilityLabel("Dismiss \(job.name) from upload history")
            }
            }.frame(width: 22, height: 26)
        }
        .frame(height: 42)
        .padding(10)
        .accessibilityElement(children: .contain).accessibilityLabel(job.name)
    }

    private var queueControls: some View {
        HStack(spacing: 8) {
            if !expanded, let showDetails {
                Button(action: showDetails) {
                    Text(pending == 0 ? "Upload history" : uploads.jobs.count > 3 ? "View all \(uploads.jobs.count) files" : "Details")
                }
            }
            Spacer(minLength: 0)
            if uploads.isActive { Button { uploads.pause() } label: { Label("Pause", systemImage: "pause") } }
            else if pending > 0 && drive.canDirectUpload {
                Button { resume() } label: { Label("Resume", systemImage: "arrow.up") }.disabled(uploads.preparing)
            }
        }.modifier(UploadButtonAppearance()).controlSize(.regular)
    }

    @ViewBuilder private var recoveryFeedback: some View {
        if pending > 0 && !drive.canDirectUpload && !uploads.isActive && drive.canEject {
            Button("Finish Finder uploads and switch") {
                Task {
                    if drive.canEject { await drive.eject() }
                    if drive.canDirectUpload { resume() }
                }
            }.modifier(UploadButtonAppearance()).disabled(drive.busy || uploads.preparing)
        } else if pending > 0 && !drive.canDirectUpload && !uploads.isActive {
            Text("Finish drive recovery to continue.").font(.caption).foregroundStyle(.orange)
        }
        if uploads.needsRecordsRecovery {
            HStack {
                Text("Upload records unavailable.").font(.caption).foregroundStyle(.orange)
                Button("Recover…") { uploads.chooseRecords(recover: true) }.font(.caption)
            }
        } else if foreignJobs > 0 {
            Text("\(foreignJobs) files need their original connection. See file details.").font(.caption).foregroundStyle(.orange)
        } else if uploads.lastOperationFailed {
            Text(uploads.message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if !uploads.message.isEmpty && (expanded || uploads.message.contains("skipped")) {
            Text(uploads.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if pending > 0 {
            if uploads.isActive {
                let active = uploads.metrics.active
                Text("\(active) uploading · \(max(0, pending - active)) waiting").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Keep your source drive connected.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var options: some View {
        Menu {
            Text("Destination: \(drive.connection.bucket)/\(drive.connection.prefix)")
            Picker("Parallel uploads", selection: Binding(get: { uploads.concurrency }, set: { uploads.changeConcurrency($0) })) {
                ForEach(DirectUploadConcurrency.allCases) { count in Text(count.label).tag(count) }
            }.disabled(uploads.isActive || uploads.preparing)
            Divider()
            Button("Use external records folder…") { uploads.chooseRecords() }.disabled(uploads.isActive || uploads.preparing)
            Button("Recover upload records…") { uploads.chooseRecords(recover: true) }.disabled(uploads.isActive || uploads.preparing)
            Button("Show records in Finder") { NSWorkspace.shared.open(uploads.recordsDirectory) }
            Divider()
            Button("Clear finished history") { uploads.clearFinished() }.disabled(uploads.isActive || uploads.preparing || !uploads.jobs.contains(where: \.terminal))
            Text("R2 normally expires incomplete uploads after 7 days.")
            if !uploads.message.isEmpty { Text(uploads.message) }
        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20).contentShape(Rectangle()) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Upload options and destination")
    }
    private func fileDetails(_ job: DirectUploadJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source: \(job.sourcePath)").textSelection(.enabled)
            Text("To: \(job.key)").textSelection(.enabled)
            if !job.message.isEmpty { Text(job.message).foregroundStyle(job.status == .attention ? Color.orange : Color.secondary) }
            if job.destination != drive.connection.fingerprint && !job.terminal {
                Text("Restore this file's original connection to resume or cancel it.").foregroundStyle(.orange)
            }
            if !job.terminal && uploads.isActive { Text("Pause uploads before cancelling a file.").foregroundStyle(.secondary) }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    private func resume() { uploads.resume(connection: drive.connection, bytesPerSecond: drive.uploadLimit.bytesPerSecond) }
    private func confirmRestart(_ job: DirectUploadJob) {
        let alert = NSAlert(); alert.messageText = "Check whether this upload has expired?"
        alert.informativeText = "If R2 has removed the saved parts, you can start again. Existing remote objects and originals are retained."
        alert.addButton(withTitle: "Check Expiration"); alert.addButton(withTitle: "Keep Saved Upload")
        if alert.runModal() == .alertFirstButtonReturn { uploads.restartExpired(job.id, connection: drive.connection) }
    }
}

/// Independent glass layers keep queue/progress updates out of the effect's view identity.
private struct UploadGlassBackdrop: View, Equatable {
    var cornerRadius: CGFloat
    var control = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cornerRadius == rhs.cornerRadius && lhs.control == rhs.control
    }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else if #available(macOS 26.0, *) {
                shape.fill(.clear)
                    .glassEffect(control ? .regular.interactive() : .regular, in: shape)
            } else {
                shape.fill(.thinMaterial)
            }
        }
        .overlay {
            shape.strokeBorder(LinearGradient(
                colors: [.white.opacity(scheme == .dark ? 0.22 : 0.8),
                         .white.opacity(scheme == .dark ? 0.035 : 0.16),
                         .white.opacity(scheme == .dark ? 0.10 : 0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .shadow(color: .black.opacity(control ? 0.05 : 0.10), radius: control ? 3 : 12, y: control ? 2 : 6)
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
    }
}
struct UploadGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background { UploadGlassBackdrop(cornerRadius: 24).equatable() }
    }
}
private struct UploadButtonAppearance: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glass) }
        else { content.buttonStyle(.bordered) }
    }
}
private struct UploadIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(RoundedRectangle(cornerRadius: 8))
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.secondary).scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0), value: configuration.isPressed)
    }
}

/// Native progress rendering. Text changes only with confirmed samples, never on animation frames.
private struct UploadConfirmedProgress: View {
    var value: Double
    var showsPercentage: Bool
    var prefix = ""
    private var clamped: Double { min(1, max(0, value.isFinite ? value : 0)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsPercentage {
                Text(prefix + "\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: clamped).progressViewStyle(.linear).tint(.accentColor)
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore).accessibilityLabel("Confirmed upload progress")
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}
private struct UploadCompletionCheck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    var body: some View {
        UploadCheckPath().trim(from: 0, to: drawn ? 1 : 0)
            .stroke(Color.green, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 14)
            .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.08)) { drawn = true } }
            .accessibilityLabel("Verified upload")
    }
}
private struct UploadCheckPath: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: rect.width * 0.15, y: rect.height * 0.52)); p.addLine(to: CGPoint(x: rect.width * 0.4, y: rect.height * 0.77)); p.addLine(to: CGPoint(x: rect.width * 0.88, y: rect.height * 0.23)) }
    }
}
/// Native URL-only drop receiver. Never asks Finder to materialize file promises or copy file contents.
struct NativeUploadDropTarget: NSViewRepresentable {
    var enabled: Bool
    var label = "Drop files or folders for direct upload"
    var activate: (() -> Void)? = nil
    var draggingChanged: (Bool) -> Void = { _ in }
    var focusChanged: (Bool) -> Void = { _ in }
    var focusRequest = UUID()
    var receive: ([URL]) -> Void
    func makeNSView(context: Context) -> UploadDropView {
        let view = UploadDropView(); view.registerForDraggedTypes([.fileURL]); view.focusRequest = focusRequest
        return view
    }
    func updateNSView(_ view: UploadDropView, context: Context) {
        view.enabled = enabled; view.receive = receive; view.activate = activate
        view.draggingChanged = draggingChanged; view.focusChanged = focusChanged
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label); view.setAccessibilityHelp("Choose or drop original files and folders. File contents stay on their source drive.")
        view.setAccessibilityEnabled(enabled)
        if view.focusRequest != focusRequest {
            view.focusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
        }
    }
}

final class UploadDropView: NSView {
    var enabled = true
    var receive: (([URL]) -> Void)?
    var activate: (() -> Void)?
    var draggingChanged: (Bool) -> Void = { _ in }
    var focusChanged: (Bool) -> Void = { _ in }
    var focusRequest = UUID()
    private var highlighted = false
    override var acceptsFirstResponder: Bool { enabled }
    private var hasFocus = false
    override func becomeFirstResponder() -> Bool {
        if !hasFocus { hasFocus = true; focusChanged(true) }
        return true
    }
    override func resignFirstResponder() -> Bool {
        if hasFocus { hasFocus = false; focusChanged(false) }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        window?.makeFirstResponder(self); activate?()
    }
    override func keyDown(with event: NSEvent) {
        if enabled && [UInt16(36), 49, 76].contains(event.keyCode) { activate?() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard enabled, let activate else { return false }
        activate(); return true
    }
    private func highlight(_ value: Bool) {
        guard highlighted != value else { return }
        highlighted = value; draggingChanged(value)
    }
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        enabled && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlight(accepts(sender)); return highlighted ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { highlight(accepts(sender)); return highlighted ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        guard enabled, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        receive?(urls); return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlight(false) }
}
