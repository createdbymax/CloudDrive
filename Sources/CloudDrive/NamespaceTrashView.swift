import SwiftUI
import CloudDriveCore

struct NamespaceTrashView: View {
    @ObservedObject var drive: Drive
    @ObservedObject private var owner: NamespaceDriveController
    @State private var entries: [NamespaceTrashEntry] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var failure = ""
    @State private var selected: NamespaceTrashEntry?
    @State private var restoreName = ""
    @State private var selectedIDs = Set<UUID>()
    @State private var deletionPrompt: TrashDeletionConfirmation?
    @State private var acceptedDeletions = Set<UUID>()
    @State private var deleting = false
    @State private var deletionFailure = ""
    init(drive: Drive) { self.drive = drive; owner = drive.namespaceEngine }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Recently Deleted", systemImage: "trash").font(.title2.bold())
                Spacer()
                Button("Refresh") { Task { await load(reset: true) } }.disabled(loading || !owner.running)
            }
            Text("Items moved here from CloudDrive stay in your drive’s hidden recovery folder until restored or explicitly deleted permanently. Finder deletion is separate. These files still use cloud storage.")
                .font(.callout).foregroundStyle(.secondary)
            if !owner.running { Text("Connect your drive to view retained files.").foregroundStyle(.secondary) }
            if !failure.isEmpty { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !owner.error.isEmpty { Text(owner.error).foregroundStyle(.orange) }
            if loading { ProgressView().controlSize(.small) }
            List(entries, selection: $selectedIDs) { entry in
                HStack {
                    Image(systemName: entry.node.kind == .directory ? "folder" : "doc")
                    VStack(alignment: .leading) {
                        Text(entry.node.name).lineLimit(1)
                        Text(entry.deletedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { selected = entry; restoreName = entry.node.name }
                        .disabled(owner.busy || owner.readOnly || !owner.running)
                        .accessibilityLabel("Restore \(entry.node.name)")
                    Button(role: .destructive) { beginDeletion([entry]) } label: { Image(systemName: "trash.slash") }
                        .disabled(owner.busy || owner.readOnly || !owner.running || deleting)
                        .help("Delete permanently…")
                        .accessibilityLabel("Delete \(entry.node.name) permanently")
                }.tag(entry.id)
            }
            .overlay { if entries.isEmpty && !loading && failure.isEmpty && owner.running { Text("No retained files").foregroundStyle(.secondary) } }
            HStack {
                Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete Selected Permanently…", role: .destructive) {
                    beginDeletion(entries.filter { selectedIDs.contains($0.id) })
                }.disabled(selectedIDs.isEmpty || owner.busy || owner.readOnly || !owner.running || deleting)
            }
            if cursor != nil { Button("Load more") { Task { await load(reset: false) } }.disabled(loading) }
        }
        .padding(20).frame(minWidth: 540, minHeight: 360)
        .task { await load(reset: true) }
        .sheet(item: $deletionPrompt) { prompt in
            VStack(alignment: .leading, spacing: 16) {
                Text(prompt.title).font(.headline)
                Text("These selected items and all folder contents will no longer be restorable through Recently Deleted. Historical cloud versions or retained backups may remain. This does not securely erase all cloud copies or guarantee reclaimed bucket space.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(prompt.entries) { entry in
                            Label(entry.node.name + (entry.node.kind == .directory ? " (folder and contents)" : ""),
                                  systemImage: acceptedDeletions.contains(entry.id) ? "checkmark.circle" : entry.node.kind == .directory ? "folder" : "doc")
                                .accessibilityValue(acceptedDeletions.contains(entry.id) ? "Deletion accepted" : "Awaiting deletion")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
                if !deletionFailure.isEmpty { Text(deletionFailure).foregroundStyle(.orange).font(.callout) }
                if deleting { ProgressView("Deleting selected items…") }
                HStack {
                    Button(deletionFailure.isEmpty ? "Cancel" : "Close") { deletionPrompt = nil }.keyboardShortcut(.cancelAction).disabled(deleting)
                    Spacer()
                    Button(acceptedDeletions.isEmpty ? "Delete Permanently" : "Delete Remaining Items", role: .destructive) {
                        Task { await deleteConfirmed(prompt) }
                    }.disabled(deleting || owner.busy || owner.readOnly || !owner.running || !deletionFailure.isEmpty)
                }
            }.padding(24).frame(width: 520).interactiveDismissDisabled(deleting)
        }
        .sheet(item: $selected) { entry in
            VStack(alignment: .leading, spacing: 16) {
                Text("Restore file").font(.headline)
                TextField("Name", text: $restoreName)
                Text("The original folder is used when available, otherwise the drive root. Existing files are never replaced; choose another name if one already exists.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { selected = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Restore") { Task {
                        await owner.restoreTrash(entry.id, name: restoreName)
                        if owner.error.isEmpty { selected = nil; await load(reset: true) }
                    } }.keyboardShortcut(.defaultAction).disabled(restoreName.isEmpty || owner.busy)
                }
                if !owner.error.isEmpty { Text(owner.error).foregroundStyle(.orange) }
            }.padding(24).frame(width: 440)
        }
    }
    private func beginDeletion(_ selected: [NamespaceTrashEntry]) {
        guard !selected.isEmpty else { return }
        acceptedDeletions = []; deletionFailure = ""
        deletionPrompt = TrashDeletionConfirmation(entries: selected, binding: drive.connection.fingerprint)
    }
    private func deleteConfirmed(_ prompt: TrashDeletionConfirmation) async {
        guard !deleting else { return }; deleting = true; deletionFailure = ""
        defer { deleting = false }
        let binding = prompt.binding
        for entry in prompt.entries where !acceptedDeletions.contains(entry.id) {
            guard drive.connection.fingerprint == binding, owner.running, !owner.readOnly else {
                deletionFailure = "The connection changed. No further items were deleted."; return
            }
            guard await owner.purgeTrash(entry.id) else {
                deletionFailure = "Deletion could not be confirmed for “\(entry.node.name)”. No further items were deleted. Refresh the list before trying again."
                return
            }
            acceptedDeletions.insert(entry.id); selectedIDs.remove(entry.id); entries.removeAll { $0.id == entry.id }
        }
        deletionPrompt = nil
        await load(reset: true)
    }
    private func load(reset: Bool) async {
        guard !loading, owner.running else { return }
        loading = true; failure = ""; defer { loading = false }
        do {
            let page = try await owner.trashEntries(after: reset ? nil : cursor)
            if reset { entries = page.entries } else { entries += page.entries.filter { next in !entries.contains { $0.id == next.id } } }
            cursor = page.next
            selectedIDs.formIntersection(Set(entries.map(\.id)))
        } catch { failure = "Retained files could not be loaded. Their contents were preserved." }
    }
}

struct TrashDeletionConfirmation: Identifiable {
    let id = UUID()
    let entries: [NamespaceTrashEntry]
    let binding: String
    var title: String { entries.count == 1 ? "Delete this item permanently?" : "Delete \(entries.count) items permanently?" }
}
