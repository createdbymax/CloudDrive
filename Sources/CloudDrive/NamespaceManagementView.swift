import SwiftUI
import CloudDriveCore

struct NamespaceManagementView: View {
    @ObservedObject var drive: Drive
    @ObservedObject private var engine: NamespaceDriveController
    @State private var selectedMode: NamespaceStorageMode = .managed
    @State private var exportFolder = ""
    @State private var showingRecentlyDeleted = false
    @State private var showingEncryptionSetup = false

    init(drive: Drive) {
        self.drive = drive
        _engine = ObservedObject(wrappedValue: drive.namespaceEngine)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("File management").font(.headline)
                Text("Save moves and edits on this Mac first, then sync them to your R2 bucket. Finder, uploads and search share the same file list.")
                    .font(.callout).foregroundStyle(.secondary)
                if engine.ownsDestination {
                    Label(engine.mode == .managed ? "Managed drive" : "Compatible bucket", systemImage: "externaldrive")
                    if engine.readOnly {
                        Text("Preview only. Your original objects remain unchanged.").font(.callout).foregroundStyle(.secondary)
                    }
                } else if !engine.encrypted {
                    Picker("Storage layout", selection: $selectedMode) {
                        Text("Compatible bucket").tag(NamespaceStorageMode.compatible)
                        Text("Managed drive").tag(NamespaceStorageMode.managed)
                    }.disabled(engine.busy)
                    NamespaceModeExplanation(mode: selectedMode)
                    if !drive.canAdoptNamespace {
                        Label("Finish existing moves and uploads, then eject the current drive before switching.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Preview this connection") {
                        Task { await engine.prepare(connection: drive.connection, mode: selectedMode, legacySafe: drive.canAdoptNamespace) }
                    }.disabled(engine.busy || !drive.canAdoptNamespace)
                        .accessibilityIdentifier("namespace-preview")
                    Button("Recover an existing managed drive") {
                        Task { await engine.prepareManagedRecovery(connection: drive.connection, legacySafe: drive.canAdoptNamespace) }
                    }.disabled(engine.busy || !drive.canAdoptNamespace)
                        .accessibilityIdentifier("namespace-managed-recovery")
                    Text("Recovery reads the published drive index into a new local store. Only uploaded changes can be recovered from R2; pending changes remain in earlier local records. Previous records and remote objects are preserved; this does not convert an ordinary bucket.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if engine.encrypted {
                    Text("Experimental encrypted managed storage").font(.subheadline.weight(.semibold))
                    Text("Encryption was selected for this connection. Existing files are not migrated. Keep your recovery kit outside this drive; this feature has not completed release qualification.")
                        .font(.caption).foregroundStyle(.secondary)
                    DriveEncryptionSetupView(drive: drive).id(drive.connection.fingerprint)
                } else if selectedMode == .managed && !engine.ownsDestination && !engine.hasSession {
                    DisclosureGroup("Encryption for a new managed drive (experimental)", isExpanded: $showingEncryptionSetup) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Optional, for a new empty prefix only. This does not migrate existing files and has not completed release qualification.")
                                .font(.caption).foregroundStyle(.secondary)
                            DriveEncryptionSetupView(drive: drive).id(drive.connection.fingerprint)
                        }.padding(.top, 8)
                    }
                }

                if engine.hasSession {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Setup progress").font(.subheadline.weight(.semibold))
                        setupStep("Storage connection prepared", complete: engine.hasSession)
                        setupStep("File list imported", complete: engine.importProgress?.complete == true || engine.enabled)
                        setupStep("Finder component included", complete: engine.extensionAvailable)
                        setupStep("Finder connection confirmed", complete: engine.mounted)
                        setupStep("File changes enabled", complete: engine.enabled && !engine.readOnly)
                        Text("You can close this window and continue later. Imported file information and accepted work are kept in local recovery records.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let progress = engine.importProgress {
                        importSummary(progress)
                    }
                    if engine.running && engine.readOnly {
                        Button("Import file list") {
                            Task { await engine.importMetadata() }
                        }.disabled(engine.busy || engine.importProgress?.complete == true)
                        Text("Import reads names and file information. It does not download file contents.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if engine.readOnly && engine.importProgress?.complete == true {
                        NamespaceModeExplanation(mode: engine.mode)
                        Button(engine.mode == .managed ? "Enable managed drive" : "Enable file changes") {
                            Task { await engine.enableWrites() }
                        }.disabled(!engine.canEnable)
                            .accessibilityIdentifier("namespace-enable")
                    }
                }

                FinderIntegrationSetupView(drive: drive)
                HStack {
                    if engine.mounted {
                        Button("Eject Finder drive") { Task { await engine.eject() } }.disabled(engine.busy)
                    } else if engine.running {
                        Button(engine.readOnly ? "Open read-only preview in Finder" : "Connect Finder browsing") { Task { await engine.mount() } }
                            .disabled(!engine.canMount || engine.importProgress?.complete != true)
                    }
                    if engine.hasSession && !engine.running {
                        Button("Recover file management") { Task { await engine.recover() } }.disabled(engine.busy)
                    }
                }
                if engine.busy { ProgressView().controlSize(.small).accessibilityLabel("File management operation in progress") }
                if !engine.error.isEmpty {
                    Label(engine.error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                } else if !engine.message.isEmpty {
                    Text(engine.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if engine.ownsDestination {
                    Divider()
                    NamespaceTransfersView(engine: engine, showsUploadButton: false)
                    Button { showingRecentlyDeleted = true } label: {
                        Label("Recently Deleted…", systemImage: "trash")
                    }.disabled(!engine.running || engine.readOnly)
                    .accessibilityIdentifier("namespace-recently-deleted")
                    if engine.mode == .managed && engine.encrypted {
                        Label("Export of decrypted ordinary files is not available yet. Keep the recovery kit to retain access to this encrypted drive.", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if engine.mode == .managed && engine.running {
                        Divider()
                        Text("Export ordinary files").font(.headline)
                        Text("Copy the published drive into a new folder under this R2 connection. Export keeps the managed drive and original objects; it does not change the drive format.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("New export folder name", text: $exportFolder)
                            .accessibilityIdentifier("namespace-export-folder")
                        Button("Export to new R2 folder") {
                            let folder = exportFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                            let prefix = drive.connection.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            Task { await engine.exportFiles(toPrefix: prefix + "/" + folder) }
                        }.disabled(!canExport || exportFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("The destination must be unused. Finish pending changes before exporting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
        .sheet(isPresented: $showingRecentlyDeleted) {
            VStack(alignment: .trailing, spacing: 12) {
                NamespaceTrashView(drive: drive)
                Button("Done") { showingRecentlyDeleted = false }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(minWidth: 600, minHeight: 400)
        }
        .onAppear { if engine.ownsDestination { selectedMode = engine.mode } }
        .onChange(of: drive.connection.fingerprint) { _, _ in showingEncryptionSetup = false; showingRecentlyDeleted = false; selectedMode = .managed }
    }
    private func setupStep(_ title: String, complete: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
            .font(.callout).foregroundStyle(complete ? Color.primary : Color.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(complete ? "Complete" : "Not complete")
    }
    private var canExport: Bool {
        guard !engine.encrypted, !engine.busy, engine.running, let status = engine.status else { return false }
        let presentation = NamespaceTransferPresentation(enabled: engine.enabled, running: engine.running, mounted: engine.mounted,
            readOnly: engine.readOnly, busy: engine.busy, status: status, error: engine.error,
            statusIsFresh: UploadFreshness.isFresh(engine.statusSampledAt, at: Date()))
        return presentation.tone == .published
    }
    private func importSummary(_ progress: NamespaceImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(progress.complete ? "File list imported" : "Import can continue", systemImage: progress.complete ? "checkmark.circle" : "arrow.triangle.2.circlepath")
            Text("\(progress.objects.formatted()) items · \(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)) in R2")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NamespaceModeExplanation: View {
    let mode: NamespaceStorageMode
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if mode == .compatible {
                Text("Compatible bucket keeps ordinary file and folder keys for other S3 tools. Local moves are saved first; relocating existing objects in R2 can still take time.")
                Text("Setup checks protected deletes using a temporary test file before enabling this mode.")
            } else {
                Text("Managed drive keeps file names separate from stored content, so cloud folder moves do not copy every file.")
                Text("This layout keeps a drive index in the connection’s prefix. Existing files stay at their original R2 keys. New files and later names are stored in the drive index.")
            }
            Text("Use one writing Mac at a time. Keep originals and recovery records until pending work is finished.")
        }.font(.caption).foregroundStyle(.secondary)
    }
}
