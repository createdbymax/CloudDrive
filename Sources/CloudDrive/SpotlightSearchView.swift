import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Arc's expanding field and unfolding results, adapted to a native drive launcher.
struct SpotlightSearchView: View {
    @ObservedObject var drive: Drive
    @ObservedObject var catalog: CatalogController
    let onDismiss: () -> Void
    @StateObject private var model: SpotlightSearchModel
    let onOpenIndex: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @FocusState private var focused: Bool
    @State private var expanded = false
    @State private var unfolded = false
    @State private var actionMessage = ""

    init(drive: Drive, catalog: CatalogController, onDismiss: @escaping () -> Void, onOpenIndex: @escaping () -> Void = {}) {
        self.drive = drive; self.catalog = catalog; self.onDismiss = onDismiss; self.onOpenIndex = onOpenIndex
        _model = StateObject(wrappedValue: SpotlightSearchModel(catalog: catalog))
    }
    private var motion: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.42, bounce: 0) }
    private var requestID: String { "\(drive.connection.fingerprint)|\(catalog.revision)|\(model.query)|\(drive.namespaceEngine.statusSampledAt?.timeIntervalSinceReferenceDate ?? 0)" }
    private var items: [CatalogObject] { Array(model.results.prefix(6)) }

    var body: some View {
        VStack(spacing: 8) {
            searchField
            if unfolded {
                resultsPanel
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: expanded || reduceMotion ? 664 : 72, alignment: .leading)
        .animation(motion, value: expanded)
        .animation(motion, value: unfolded)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { Color.clear.contentShape(Rectangle()).onTapGesture(perform: onDismiss) }
        .onExitCommand(perform: onDismiss)
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .task {
            catalog.configure(connection: drive.connection)
            expanded = true
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 80)) } catch { return }
            focused = true
            unfolded = true
        }
        .task(id: requestID) { await model.search(scope: drive.connection.fingerprint) }
        .onChange(of: model.query) { _, _ in actionMessage = "" }
    }

    private var searchField: some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 25, weight: .regular)).foregroundStyle(.secondary)
                .frame(width: 28).accessibilityHidden(true)
            if expanded || reduceMotion {
                TextField("Search your drive", text: $model.query)
                    .font(.system(size: 25, weight: .regular))
                    .textFieldStyle(.plain).focused($focused)
                    .accessibilityLabel("Search drive file names and paths")
                    .onSubmit { activateSelected(reveal: NSEvent.modifierFlags.contains(.command)) }
                    .layoutPriority(1)
                if model.searching {
                    ProgressView().controlSize(.small).frame(width: 26)
                        .accessibilityLabel("Searching local index")
                } else if !model.query.isEmpty {
                    Button { model.query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                } else {
                    Text(SearchShortcut.saved().label).font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                        .fixedSize().accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 23).frame(height: 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SearchGlassSurface(radius: expanded ? 24 : 36))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "FROM YOUR DRIVE" : "FILES")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                if catalog.scanning { ProgressView().controlSize(.mini); Text("Indexing") }
                else { Image(systemName: "externaldrive"); Text("\(catalog.summary.count.formatted()) indexed") }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 8)

            if !model.error.isEmpty {
                message(title: "Search unavailable", detail: model.error, symbol: "exclamationmark.magnifyingglass")
            } else if catalog.loading || model.searching && items.isEmpty {
                message(title: "Searching your index…", detail: "File names and paths, right on this Mac.", symbol: "magnifyingglass")
            } else if items.isEmpty {
                if catalog.summary.count == 0 {
                    message(title: catalog.scanning ? "Building your index" : "Your drive, a few keystrokes away",
                            detail: catalog.scanning ? "Files appear here as they are indexed." : "Create an index to find files, even while offline.", symbol: "doc.text.magnifyingglass")
                    Button("Open index settings") { openIndex() }
                        .buttonStyle(.bordered).padding(.leading, 22).padding(.bottom, 18)
                } else {
                    message(title: "No matching files", detail: "Try the beginning of a file name or a folder name.", symbol: "magnifyingglass")
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { item in resultRow(item) }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
            Divider().opacity(0.45).padding(.horizontal, 16)
            footer
        }
        .frame(width: 664)
        .modifier(SearchGlassSurface(radius: 24))
        .shadow(color: .black.opacity(0.14), radius: 22, y: 12)
        .animation(reduceMotion ? nil : motion, value: model.selectedID)
    }

    private func resultRow(_ item: CatalogObject) -> some View {
        let active = model.selectedID == item.id
        return Button { model.selectedID = item.id; activateSelected(reveal: false) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(item)).font(.system(size: 21, weight: .regular))
                    .foregroundStyle(iconColor(item)).frame(width: 34, height: 34)
                    .background(iconColor(item).opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(item.name.isEmpty ? "Directory marker" : item.name))
                        .font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                    Text(displayParent(item)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                AvailabilityBadge(value: item.availability, checkedAt: item.availabilityCheckedAt, iconOnly: true)
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.secondary)
                    .opacity(active ? 1 : 0).frame(width: 16)
            }
            .padding(.horizontal, 12).frame(height: 54).contentShape(RoundedRectangle(cornerRadius: 16))
            .background {
                if active {
                    if reduceMotion {
                        RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.07))
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.07))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { model.selectedID = item.id } }
        .accessibilityLabel("\(item.name), \(displayParent(item))" + (CatalogAvailability.effective(item.availability, checkedAt: item.availabilityCheckedAt, at: Date()).map { ", " + $0.label } ?? ""))
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .contextMenu {
            Button("Open") { model.selectedID = item.id; activateSelected(reveal: false) }
            Button("Reveal in Finder") { model.selectedID = item.id; activateSelected(reveal: true) }
            Button(drive.namespaceEngine.enabled ? "Copy file path" : "Copy object key") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.key, forType: .string)
            }
            NamespaceFileActions(drive: drive, item: item)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↑↓").fontWeight(.medium) + Text(" Navigate")
            if drive.finderMounted {
                Text("↵ Open")
                Button("⌘↵ Reveal") { activateSelected(reveal: true) }.buttonStyle(.plain)
                    .disabled(model.selectedResult == nil)
            } else if drive.canConnect {
                Button("Connect Finder to open") { Task { await drive.start() } }.buttonStyle(.plain)
            } else { Text("Connect Finder to open") }
            Spacer(minLength: 4)
            Button { openIndex() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Open full search and index controls").accessibilityLabel("Open full search and index controls")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .overlay(alignment: .bottomLeading) {
            if !actionMessage.isEmpty {
                Text(actionMessage).font(.caption).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(.bottom, 44).padding(.leading, 16)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
    private func message(title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary).frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 22).padding(.vertical, 24)
    }
    private func openIndex() { onOpenIndex() }
    private func activateSelected(reveal: Bool) {
        guard let item = model.selectedResult else { return }
        guard drive.finderMounted else { actionMessage = "Connect Finder browsing to open this file."; return }
        guard let url = CatalogText.mountURL(key: item.key, prefix: drive.connection.prefix, mount: drive.browsingMountpoint) else {
            actionMessage = "This object cannot be opened as a Finder path. Copy its key from the context menu."; return
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]); onDismiss() }
        else if NSWorkspace.shared.open(url) { onDismiss() }
        else { actionMessage = "The file could not be opened. Try revealing it in Finder." }
    }
    private func displayParent(_ item: CatalogObject) -> String {
        let prefix = drive.connection.prefix + "/"
        let parent = item.parent.hasPrefix(prefix) ? String(item.parent.dropFirst(prefix.count)) : item.parent
        return parent.isEmpty ? "CloudDrive" : "CloudDrive / " + parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private func highlighted(_ name: String) -> AttributedString {
        var value = AttributedString(name)
        for term in (try? CatalogQuery(text: model.query).terms()) ?? [] {
            if let range = value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                value[range].font = .system(size: 14, weight: .semibold)
            }
        }
        return value
    }
    private func symbol(_ item: CatalogObject) -> String {
        if item.key.hasSuffix("/") { return "folder.fill" }
        let type = UTType(filenameExtension: item.fileExtension)
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc.text"
    }
    private func iconColor(_ item: CatalogObject) -> Color {
        switch symbol(item) {
        case "waveform": return .pink
        case "film": return .purple
        case "photo": return .orange
        case "folder.fill": return .blue
        default: return .secondary
        }
    }
}

private struct SearchGlassSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.12)) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.10)) }
        }
    }
}
