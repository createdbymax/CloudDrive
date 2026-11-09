import SwiftUI
import AppKit

struct SearchView: View {
    @ObservedObject var drive: Drive
    @ObservedObject var catalog: CatalogController
    @State private var text = ""
    @State private var ext = ""
    @State private var largeOnly = false
    @State private var selected: Data?
    @FocusState private var focused: Bool
    private var requestID: String { "\(drive.connection.fingerprint)|\(catalog.revision)|\(text)|\(ext)|\(largeOnly)|\(drive.namespaceEngine.statusSampledAt?.timeIntervalSinceReferenceDate ?? 0)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search file names and paths", text: $text)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityLabel("Search file names and paths")
                    .onSubmit { openSelected(reveal: false) }
                if catalog.searching { ProgressView().controlSize(.small).accessibilityLabel("Searching saved inventory") }
            }
            HStack {
                TextField("Extension (e.g. wav)", text: $ext).textFieldStyle(.roundedBorder).frame(width: 170)
                    .accessibilityLabel("File extension filter")
                Toggle("At least 1 GB", isOn: $largeOnly)
                Spacer()
                if catalog.scanning {
                    Button("Pause indexing") { catalog.pause() }
                } else {
                    Button(catalog.summary.count == 0 ? "Index drive" : "Refresh index") { catalog.refresh() }.disabled(catalog.loading || drive.needsSetup)
                    Menu {
                        Button("Start fresh scan") { catalog.refresh(fresh: true) }
                        if catalog.automaticEnabled {
                            Button(catalog.automaticPaused ? "Resume automatic updates" : "Pause automatic updates") {
                                if catalog.automaticPaused { catalog.refresh() } else { catalog.pause() }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Index options").disabled(catalog.loading || drive.needsSetup)
                }
            }
            HStack {
                Text("\(catalog.summary.count.formatted()) saved entries").monospacedDigit()
                if catalog.scanning { Text("· Indexing…") }
                else if catalog.summary.hasPartialScan { Text("· Partial refresh") }
                else if let date = catalog.summary.lastCompleted { Text("· Last checked \(date.formatted(date: .abbreviated, time: .shortened))") }
                else { Text("· Inventory not complete") }
            }.font(.caption).foregroundStyle(.secondary)
            if catalog.automaticEnabled {
                Text(catalog.automaticPaused ? "Automatic updates paused" : "Automatic updates on · file changes are checked in the background")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !catalog.automaticStatus.isEmpty { Text(catalog.automaticStatus).font(.caption).foregroundStyle(.secondary) }
            if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !catalog.searchError.isEmpty { Text(catalog.searchError).foregroundStyle(.red).font(.callout) }
            Table(catalog.results, selection: $selected) {
                TableColumn("Name") { item in
                    Label(item.name.isEmpty ? "Directory marker" : item.name, systemImage: item.key.hasSuffix("/") ? "folder" : "doc")
                }.width(min: 140, ideal: 220)
                TableColumn("Folder") { item in Text(item.parent).foregroundStyle(.secondary) }.width(min: 100, ideal: 220)
                TableColumn("Availability") { item in
                    AvailabilityBadge(value: item.availability, checkedAt: item.availabilityCheckedAt)
                }.width(min: 110, ideal: 170)
                TableColumn("Size") { item in Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).monospacedDigit() }.width(85)
                TableColumn("Modified") { item in Text(item.modified.formatted(date: .abbreviated, time: .omitted)) }.width(100)
            }
            .contextMenu(forSelectionType: Data.self) { ids in
                if let id = ids.first, let item = catalog.results.first(where: { $0.id == id }) {
                    Button("Open") { open(item, reveal: false) }.disabled(!canOpen(item))
                    Button("Reveal in Finder") { open(item, reveal: true) }.disabled(!canOpen(item))
                    Button(drive.namespaceEngine.enabled ? "Copy file path" : "Copy object key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.key, forType: .string) }
                    NamespaceFileActions(drive: drive, item: item)
                }
            } primaryAction: { ids in
                if let id = ids.first, let item = catalog.results.first(where: { $0.id == id }) { open(item, reveal: false) }
            }
            HStack {
                Text(catalog.results.count == 100 ? "Showing the first 100 results. Add words or filters to narrow the search." : "Search uses saved metadata and works offline. Words match token prefixes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") { openSelected(reveal: true) }.disabled(!selectedCanOpen)
            }
            if !drive.finderMounted {
                HStack {
                    Text("Connect Finder to open files. Uncached file contents require a network connection.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect Finder") { Task { await drive.start() } }.disabled(!drive.canConnect)
                }
            }
        }
        .padding(20).frame(minWidth: 720, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
        .onChange(of: drive.connection.fingerprint) { _, _ in selected = nil }
        .onChange(of: catalog.results) { old, new in
            selected = CatalogSelection.reconcile(selected, previous: old, updated: new)
        }
        .task(id: drive.connection.fingerprint) { catalog.configure(connection: drive.connection); focused = true }
        .task(id: requestID) {
            await catalog.search(CatalogQuery(text: text, fileExtension: ext, minimumSize: largeOnly ? 1_000_000_000 : 0, limit: 100))
        }
    }
    private var selectedCanOpen: Bool { selected.flatMap { id in catalog.results.first { $0.id == id } }.map(canOpen) ?? false }
    private func canOpen(_ item: CatalogObject) -> Bool {
        drive.finderMounted && CatalogText.mountURL(key: item.key, prefix: drive.connection.prefix, mount: drive.browsingMountpoint) != nil
    }
    private func openSelected(reveal: Bool) {
        if let selected, let item = catalog.results.first(where: { $0.id == selected }) { open(item, reveal: reveal) }
    }
    private func open(_ item: CatalogObject, reveal: Bool) {
        guard drive.finderMounted, let url = CatalogText.mountURL(key: item.key, prefix: drive.connection.prefix, mount: drive.browsingMountpoint) else { return }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
    }
}
