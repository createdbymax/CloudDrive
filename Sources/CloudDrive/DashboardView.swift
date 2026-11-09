import SwiftUI
import AppKit

enum DashboardDestination: String, CaseIterable, Identifiable {
    case drive = "Drive", uploads = "Transfers"
    var id: String { rawValue }
    var symbol: String { self == .drive ? "externaldrive" : "arrow.up.arrow.down" }
}
enum UploadSource: String, CaseIterable, Identifiable {
    case direct = "Direct uploads", finder = "Finder uploads"
    var id: String { rawValue }
}

/// Navigation owns no transfer tasks. The app delegate keeps Drive and its queue alive.
@MainActor final class DashboardNavigation: ObservableObject {
    @Published var destination: DashboardDestination? = .drive
    @Published var uploadSource = UploadSource.finder
    @Published var uploadFilter = DirectUploadFilter.queue
    func showUploads(source: UploadSource = .finder, history: Bool = false) {
        uploadSource = history ? .direct : source
        uploadFilter = history ? .completed : .queue
        destination = .uploads
    }
}

struct ContentView: View {
    @ObservedObject var drive: Drive
    @ObservedObject var navigation = DashboardNavigation()
    var showSearch: () -> Void = {}
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.destination) {
                ForEach(DashboardDestination.allCases) { destination in
                    NavigationLink(value: destination) {
                        Label(destination.rawValue, systemImage: destination.symbol)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("CloudDrive")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsLink { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                    Button { openWindow(id: "recovery") } label: {
                        Label("Recovery", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.modifier(DriveButtonAppearance()).padding(12)
            }
        } detail: {
            switch navigation.destination ?? .drive {
            case .drive:
                DriveWorkspaceView(drive: drive, navigation: navigation, showSearch: showSearch)
            case .uploads:
                UploadWorkspaceView(drive: drive, navigation: navigation)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 500)
    }
}

struct DriveWorkspaceView: View {
    @ObservedObject var drive: Drive
    @ObservedObject var navigation: DashboardNavigation
    var showSearch: () -> Void = {}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Drive").font(.title2.weight(.semibold))
                        Text("Cloudflare R2").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    if let session = drive.movePickerSession {
                        Button("Move Item…") { Task { await chooseMove(session: session) } }
                    }
                    if !drive.needsSetup && drive.finderMounted {
                        Button { drive.openDrive() } label: { Text("Open in Finder").frame(minHeight: 22) }
                            .modifier(DriveButtonAppearance(prominent: true)).controlSize(.large)
                            .keyboardShortcut("o", modifiers: .command).help("Open in Finder (⌘O)")
                    }
                }
                if drive.needsSetup { SetupView(drive: drive) }
                else {
                    StatusCard(drive: drive)
                    Button(action: showSearch) { Label("Search Drive…", systemImage: "magnifyingglass") }
                        .help("Search your drive")
                    if drive.directUploads.hasUnfinishedOrUnavailableQueue {
                        DashboardUploadSummary(uploads: drive.directUploads) { navigation.showUploads(source: .direct) }
                    }
                    if drive.storageWorkerRunning && drive.activityAvailable, let snapshot = drive.uploadProgress, !snapshot.isEmpty {
                        CompactTransfers(snapshot: snapshot, sampledAt: drive.uploadSampledAt) { navigation.showUploads(source: .finder) }
                    }
                    if drive.mountState == .blocked || drive.keychainNeedsApproval { RecoveryActions(drive: drive) }
                    if drive.operationBusy || drive.lastOperationFailed || drive.keychainNeedsApproval || drive.mountState == .blocked || (drive.mountState == .unmounted && drive.storageWorkerRunning) { OperationFeedback(drive: drive) }
                    if !drive.namespaceEngine.ownsDestination { FinderMovesView(drive: drive) }
                    if drive.canConnect && !drive.keychainNeedsApproval {
                        Button("Connect Drive") { Task { await drive.start() } }
                    }
                    Divider()
                    StorageSummary(drive: drive, compact: false)
                    if drive.finderMounted || drive.storageWorkerRunning || drive.canEject {
                        Button { Task { await drive.eject() } } label: { Label(drive.ejectActionTitle, systemImage: "eject") }
                            .disabled(!drive.canEject)
                    }
                }
            }.padding(28).frame(maxWidth: 760).frame(maxWidth: .infinity, alignment: .top)
        }
        .modifier(DriveButtonAppearance()).background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Drive")
    }
    @MainActor private func chooseMove(session: UUID) async {
        let item = NSOpenPanel()
        item.title = "Choose an item to move"
        item.prompt = "Choose Item"
        item.canChooseDirectories = true
        item.canChooseFiles = true
        item.directoryURL = drive.mountpoint
        guard await item.begin() == .OK, let source = item.url else { return }

        await drive.chooseDestinationAndMove(source: source, session: session)
    }

}

struct DashboardUploadSummary: View {
    @ObservedObject var uploads: DirectUploadController
    var showUploads: () -> Void
    private var title: String {
        if uploads.needsRecordsRecovery { return "Saved uploads need recovery" }
        if uploads.preparing { return "Preparing uploads…" }
        if uploads.isActive { return "Uploading · \(Int(uploads.progress * 100))%" }
        if uploads.metrics.attention > 0 { return "\(uploads.metrics.attention) uploads need attention" }
        if uploads.metrics.pending > 0 { return "Uploads paused · \(Int(uploads.progress * 100))%" }
        return "Saved uploads"
    }
    var body: some View {
        Button(action: showUploads) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up").font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(uploads.isActive ? UploadMetricText.remaining(uploads.eta) : uploads.metrics.pending > 0 ? "\(uploads.metrics.pending) files in your queue" : "Review the saved upload queue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(UploadGlassSurface()).contentShape(RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).accessibilityLabel("Open uploads. " + title)
    }
}

struct UploadWorkspaceView: View {
    @ObservedObject var drive: Drive
    @ObservedObject var navigation: DashboardNavigation
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.title2.weight(.semibold))
                Spacer()
                if navigation.uploadSource == .direct {
                    Button("Back to drive transfers") { navigation.showUploads(source: .finder) }
                } else if drive.directUploads.hasSavedTransferRecords {
                    Button(drive.directUploads.hasUnfinishedOrUnavailableQueue ? "Review saved uploads…" : "Upload history…") {
                        navigation.showUploads(source: .direct, history: !drive.directUploads.hasUnfinishedOrUnavailableQueue)
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if navigation.uploadSource == .direct {
                ScrollView {
                    DirectUploadCard(drive: drive, uploads: drive.directUploads, expanded: true,
                                     workspace: true, filter: $navigation.uploadFilter)
                        .padding(24).frame(maxWidth: 960).frame(maxWidth: .infinity, alignment: .top)
                }
            } else if drive.namespaceEngine.ownsDestination {
                ScrollView { NamespaceTransfersView(engine: drive.namespaceEngine).padding(24) }
            } else if drive.needsSetup {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Connect CloudDrive to see your transfers.").foregroundStyle(.secondary)
                    Button("Set Up Drive") { navigation.destination = .drive }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TransfersView(drive: drive)
            }
        }.background(Color(nsColor: .windowBackgroundColor)).navigationTitle("Transfers")
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
                    Text(status.title)
                        .font(.headline)
                    Text(status.subtitle)
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
            if drive.operationBusy {
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
                    Text(drive.storageWorkerRunning && drive.automaticSpaceSaving ? "Automatic" : "Details")
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
            Text(drive.namespaceEngine.enabled ? "Changes are saved on this Mac before syncing. Files kept downloaded stay available offline; recent-read cache can be released." : drive.storagePolicyText)
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CompactTransfers: View {
    let snapshot: UploadProgressSnapshot
    let sampledAt: Date?
    var showUploads: () -> Void = {}
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
            Button("Show Finder uploads", action: showUploads)
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
