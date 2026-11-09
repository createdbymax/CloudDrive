import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

// Native translation of https://uiarc.dev/components/blocks/file-upload
// Isolated experiment: no CloudDrive dependencies, network requests, or bucket writes.
// The adjacent Xcode project runs this file with UIARC_FILE_UPLOAD_DEMO defined.

private enum ArcStyle {
    static let smooth = Animation.spring(duration: 0.4, bounce: 0)
    static let snappy = Animation.spring(duration: 0.26, bounce: 0)
    static let enter = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.24)
    static let fast = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.16)
    // Reference's neutral OKLCH colors converted to sRGB; deliberately independent of macOS accent.
    static func neutral(_ lightness: Double) -> Color {
        let linear = pow(lightness, 3)
        let value = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return Color(.sRGB, red: value, green: value, blue: value)
    }
    static let foreground = neutral(0.15), muted = neutral(0.59), secondary = neutral(0.46)
    static let accent = neutral(0.33), strong = neutral(0.24)
    static let border = neutral(0.935), borderStrong = neutral(0.82), borderSubtle = neutral(0.965)
    static let surfaceMuted = neutral(0.978)
    static let success = Color(.sRGB, red: 0.091, green: 0.463, blue: 0.321)
    static let danger = Color(.sRGB, red: 0.733, green: 0.172, blue: 0.314)
    static let registerFont: Void = {
        let url = Bundle.main.url(forResource: "Inter", withExtension: "ttf")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Inter.ttf")
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
    static func font(_ size: CGFloat, medium: Bool = false) -> Font {
        _ = registerFont
        return .custom("Inter", size: size).weight(medium ? .medium : .regular)
    }
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        let mb = Double(bytes) / (1024 * 1024)
        return "\(mb >= 10 ? String(Int(mb.rounded())) : String(format: "%.1f", mb).replacingOccurrences(of: ".0", with: "")) MB"
    }
}

struct ArcUploadFile: Identifiable {
    enum Phase { case ready, uploading, done, failed }
    let id: UUID
    let url: URL
    let bytes: Int64
    var error: String?
    var phase: Phase
    var progress: Double
    init(id: UUID = UUID(), url: URL, bytes: Int64, error: String? = nil,
         phase: Phase = .ready, progress: Double = 0) {
        self.id = id; self.url = url; self.bytes = bytes; self.error = error
        self.phase = phase; self.progress = progress
    }
}

/// Standalone selection/upload presentation. With no handler, valid files are marked Ready.
/// The handler runs on the main actor; suspend during I/O and check Task cancellation.
@MainActor
struct ArcFileUploadView: View {
    typealias UploadHandler = @MainActor (URL, @escaping @MainActor (Double) -> Void) async throws -> Void
    var label = "Upload files"
    var description = "Drop files here or browse from your device."
    var acceptedTypes: [UTType] = []
    var maximumSize: Int64? = nil
    var multiple = true
    var disabled = false
    var onUpload: UploadHandler? = nil
    @State var files: [ArcUploadFile] = []
    @State private var tasks: [UUID: Task<Void, Never>] = [:]
    @State private var generations: [UUID: UUID] = [:]
    @State private var dragging = false
    @State private var hovering = false
    @State private var announcement = ""
    @FocusState private var focus: Focus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Focus: Hashable { case dropzone, remove(UUID) }
    private var animation: Animation { reduceMotion ? .linear(duration: 0.12) : ArcStyle.smooth }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: browse) {
                HStack(spacing: 12) {
                    ArcIcon(kind: .cloud).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 20, height: 20).frame(width: 24, height: 24)
                        .foregroundStyle(ArcStyle.strong)
                        .offset(y: dragging && !reduceMotion ? -3 : 0)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dragging ? "Drop to add \(multiple ? "files" : "a file")" : label)
                            .font(ArcStyle.font(14, medium: true)).frame(height: 19.6)
                            .id(dragging).transition(textTransition)
                        Text(description).font(ArcStyle.font(12)).foregroundStyle(ArcStyle.muted)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Browse").font(ArcStyle.font(12, medium: true)).foregroundStyle(ArcStyle.strong)
                }
                .padding(17).frame(minHeight: 92)
                .background((dragging || hovering) && !disabled ? ArcStyle.accent.opacity(0.1) : .white)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .overlay {
                    RoundedRectangle(cornerRadius: 26).inset(by: 0.5)
                        .strokeBorder(dragging || hovering ? ArcStyle.accent : ArcStyle.borderStrong,
                                      style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                .overlay {
                    if focus == .dropzone {
                        RoundedRectangle(cornerRadius: 28).stroke(ArcStyle.accent.opacity(0.5), lineWidth: 2).padding(-3)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 26))
            }
            .buttonStyle(ArcDropButtonStyle(reduceMotion: reduceMotion))
            .focused($focus, equals: .dropzone)
            .disabled(disabled).opacity(disabled ? 0.52 : 1)
            .onHover { hovering = $0 }
            .onDrop(of: [.fileURL], isTargeted: $dragging, perform: receiveDrop)
            .accessibilityLabel(dragging ? "Drop to add files" : label)
            .accessibilityHint(description)
            .animation(reduceMotion ? nil : ArcStyle.enter, value: dragging)
            .animation(reduceMotion ? nil : ArcStyle.enter, value: hovering)

            if !announcement.isEmpty {
                Text(announcement).font(ArcStyle.font(12)).foregroundStyle(ArcStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    .id(announcement).transition(textTransition.combined(with: revealTransition))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if !files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        ArcFileRow(file: file, retry: { start(file.id) }, remove: { remove(file.id) },
                                   removeFocus: $focus, focusValue: .remove(file.id))
                            .padding(.top, 6).transition(revealTransition)
                    }
                }
                .padding(.top, 6).transition(revealTransition)
                .accessibilityElement(children: .contain).accessibilityLabel("Selected files")
            }
        }
        .foregroundStyle(ArcStyle.foreground)
        .animation(animation, value: files.map(\.id))
        .animation(animation, value: announcement.isEmpty)
        .onDisappear { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
    }

    private var revealTransition: AnyTransition {
        reduceMotion ? .opacity : .modifier(active: ArcReveal(fraction: 0), identity: ArcReveal(fraction: 1)).combined(with: .opacity)
    }
    private var textTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4.2)).combined(with: .blurArc(4)),
            removal: .opacity.combined(with: .offset(y: -4.2)).combined(with: .blurArc(2)))
    }
    private func browse() {
        guard !disabled else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = multiple
        // Keep all types selectable so invalid files receive the same inline feedback as the reference.
        panel.begin { response in
            if response == .OK { Task { @MainActor in add(panel.urls) } }
        }
    }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !disabled else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        continuation.resume(returning: url)
                    }
                }
                if let url { urls.append(url) }
            }
            add(urls)
        }
        return true
    }
    private func add(_ urls: [URL]) {
        let incoming = (multiple ? urls : Array(urls.prefix(1))).map { url -> ArcUploadFile in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
            let bytes = Int64(values?.fileSize ?? 0)
            let accepted = acceptedTypes.isEmpty || acceptedTypes.contains { values?.contentType?.conforms(to: $0) == true }
            let error: String? = values?.isDirectory == true ? "This file type is not accepted."
                : !accepted ? "This file type is not accepted."
                : maximumSize.map { bytes > $0 } == true ? "File is larger than \(ArcStyle.size(maximumSize!))." : nil
            return ArcUploadFile(url: url, bytes: bytes, error: error)
        }
        guard !incoming.isEmpty else { return }
        if !multiple { tasks.values.forEach { $0.cancel() }; tasks.removeAll(); files = [] }
        withAnimation(animation) { files.append(contentsOf: incoming) }
        let invalid = incoming.filter { $0.error != nil }.count
        let valid = incoming.count - invalid
        let added = "\(valid) file\(valid == 1 ? "" : "s") added."
        let attention = "\(invalid) file\(invalid == 1 ? " needs" : "s need") attention."
        announce(invalid == 0 ? added : valid > 0 ? added + " " + attention : attention)
        incoming.filter { $0.error == nil }.forEach { start($0.id) }
    }
    private func start(_ id: UUID) {
        guard let onUpload, let index = files.firstIndex(where: { $0.id == id }), files[index].error == nil else { return }
        tasks[id]?.cancel()
        files[index].phase = .uploading; files[index].progress = 0
        let url = files[index].url
        let generation = UUID()
        generations[id] = generation
        tasks[id] = Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await onUpload(url) { percent in
                    guard !Task.isCancelled, generations[id] == generation, let i = files.firstIndex(where: { $0.id == id }) else { return }
                    files[i].progress = max(files[i].progress, min(100, max(0, percent)))
                }
                try Task.checkCancellation()
                guard let i = files.firstIndex(where: { $0.id == id }) else { return }
                files[i].progress = 100; files[i].phase = .done
                announce("\(url.lastPathComponent) uploaded.")
            } catch {
                guard !Task.isCancelled, generations[id] == generation, let i = files.firstIndex(where: { $0.id == id }) else { return }
                files[i].phase = .failed
                announce("\(url.lastPathComponent) could not be uploaded.")
            }
            tasks[id] = nil
        }
    }
    private func remove(_ id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let name = files[index].url.lastPathComponent
        let neighbor = index + 1 < files.count ? files[index + 1].id : index > 0 ? files[index - 1].id : nil
        tasks.removeValue(forKey: id)?.cancel()
        generations[id] = nil
        withAnimation(animation) { _ = files.remove(at: index) }
        focus = neighbor.map(Focus.remove) ?? .dropzone
        announce("\(name) removed.")
    }
    private func announce(_ text: String) {
        withAnimation(reduceMotion ? .linear(duration: 0.12) : ArcStyle.enter) { announcement = text }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

private struct ArcFileRow<Focus: Hashable>: View {
    let file: ArcUploadFile
    let retry: () -> Void
    let remove: () -> Void
    var removeFocus: FocusState<Focus?>.Binding
    var focusValue: Focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedProgress = 0.0
    @State private var settled = false
    @State private var showBar = false
    private var uploading: Bool { file.phase == .uploading || file.phase == .done && !settled }
    private var complete: Bool { file.phase == .done && settled || file.phase == .ready }
    private var kind: ArcIcon.Kind {
        let type = UTType(filenameExtension: file.url.pathExtension)
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .text) == true { return .text }
        if ["zip", "gz"].contains(file.url.pathExtension) { return .archive }
        return .file
    }
    var body: some View {
        HStack(spacing: 12) {
            ArcIcon(kind: kind).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16).frame(width: 24, height: 24).foregroundStyle(ArcStyle.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).font(ArcStyle.font(14, medium: true)).lineLimit(1)
                    .truncationMode(.tail).frame(height: 19.6).help(file.url.lastPathComponent)
                HStack(spacing: 0) {
                    Text(ArcStyle.size(file.bytes))
                    if file.phase != .ready {
                        Text("·").padding(.horizontal, 5)
                        Group {
                            if uploading { ArcProgressLabel(value: displayedProgress) }
                            else { Text(file.phase == .failed ? "Upload failed" : "Uploaded") }
                        }
                        .foregroundStyle(file.phase == .failed ? ArcStyle.danger : ArcStyle.muted)
                        .id(uploading ? "uploading" : file.phase == .failed ? "failed" : "done")
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 3.6)).combined(with: .blurArc(2)))
                    }
                }
                .font(ArcStyle.font(12)).foregroundStyle(ArcStyle.muted).monospacedDigit().frame(height: 16.8)
                if let error = file.error { Text(error).font(ArcStyle.font(12)).foregroundStyle(ArcStyle.danger) }
                if showBar {
                    ArcProgressBar(value: displayedProgress).frame(height: 3).padding(.top, 5).padding(.bottom, 1)
                        .transition(reduceMotion ? .opacity : .modifier(active: ArcReveal(fraction: 0), identity: ArcReveal(fraction: 1)).combined(with: .opacity))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                if file.error == nil && complete {
                    ArcDrawnCheck().transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.8)))
                        .accessibilityLabel(file.phase == .done ? "Uploaded" : "Ready")
                }
                if file.phase == .failed && file.error == nil {
                    Button(action: retry) { ArcIcon(kind: .retry).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 14, height: 14) }
                        .buttonStyle(ArcIconButtonStyle()).accessibilityLabel("Retry \(file.url.lastPathComponent)")
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.6)))
                }
            }.frame(width: 26, height: 26)
            Button(action: remove) { ArcIcon(kind: .close).stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: 15, height: 15) }
                .buttonStyle(ArcIconButtonStyle()).focused(removeFocus, equals: focusValue)
                .accessibilityLabel("Remove \(file.url.lastPathComponent)")
        }
        .padding(.leading, 13).padding(.trailing, 11).padding(.vertical, 11)
        .background(ArcStyle.surfaceMuted, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(ArcStyle.borderSubtle, lineWidth: 1) }
        .animation(reduceMotion ? .linear(duration: 0.12) : ArcStyle.enter, value: uploading)
        .animation(reduceMotion ? .linear(duration: 0.12) : ArcStyle.snappy, value: complete)
        .onAppear { update() }.onChange(of: file.progress) { _, _ in update() }
        .onChange(of: file.phase) { _, _ in update() }
        .task(id: uploading) {
            if uploading { withAnimation(reduceMotion ? nil : ArcStyle.smooth) { showBar = true } }
            else {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 240))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : ArcStyle.smooth) { showBar = false }
            }
        }
    }
    private func update() {
        if file.phase == .uploading { settled = false }
        if reduceMotion || file.phase == .uploading && file.progress == 0 {
            displayedProgress = file.progress; settled = file.phase == .done
        } else {
            withAnimation(ArcStyle.smooth, completionCriteria: .logicallyComplete) {
                displayedProgress = file.phase == .done ? 100 : file.progress
            } completion: {
                if file.phase == .done { withAnimation(ArcStyle.enter) { settled = true } }
            }
        }
    }
}

// Both views interpolate the same scalar on the same spring: bar and rounded count remain in sync.
private struct ArcProgressLabel: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("Uploading \(Int(min(100, max(0, value)).rounded()))%") }
}
private struct ArcProgressBar: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(ArcStyle.border).overlay(alignment: .leading) {
                Capsule().fill(ArcStyle.accent).frame(width: geometry.size.width)
                    .offset(x: geometry.size.width * (min(100, max(0, value)) / 100 - 1))
            }.clipShape(Capsule())
        }.accessibilityLabel("Upload progress").accessibilityValue("\(Int(value)) percent")
    }
}
private struct ArcDrawnCheck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    var body: some View {
        ArcIcon(kind: .check).trim(from: 0, to: drawn ? 1 : 0)
            .stroke(ArcStyle.success, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 14)
            .onAppear { withAnimation(reduceMotion ? nil : ArcStyle.enter.delay(0.08)) { drawn = true } }
    }
}
private struct ArcReveal: ViewModifier, Animatable {
    var fraction: CGFloat
    var animatableData: CGFloat { get { fraction } set { fraction = newValue } }
    func body(content: Content) -> some View { ArcRevealLayout(fraction: fraction) { content }.clipped() }
}
private struct ArcRevealLayout: Layout {
    var fraction: CGFloat
    var animatableData: CGFloat { get { fraction } set { fraction = newValue } }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * max(0, fraction))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let full = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: full.height))
    }
}
private struct ArcBlur: ViewModifier { let radius: CGFloat; func body(content: Content) -> some View { content.blur(radius: radius) } }
private extension AnyTransition { static func blurArc(_ radius: CGFloat) -> AnyTransition { .modifier(active: ArcBlur(radius: radius), identity: ArcBlur(radius: 0)) } }
private struct ArcDropButtonStyle: ButtonStyle {
    var reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.overlay {
            RoundedRectangle(cornerRadius: 26).fill(ArcStyle.accent.opacity(configuration.isPressed ? 0.1 : 0))
                .allowsHitTesting(false)
        }.animation(reduceMotion ? nil : ArcStyle.fast, value: configuration.isPressed)
    }
}
private struct ArcIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View { IconButtonBody(configuration: configuration, reduceMotion: reduceMotion) }
    private struct IconButtonBody: View {
        let configuration: Configuration
        let reduceMotion: Bool
        @State private var hover = false
        var body: some View {
            configuration.label.frame(width: 26, height: 26)
                .foregroundStyle(hover ? ArcStyle.foreground : ArcStyle.muted)
                .background(hover ? Color.white : .clear, in: Capsule())
                .contentShape(Capsule()).scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .onHover { hover = $0 }
                .animation(reduceMotion ? nil : ArcStyle.fast, value: hover)
                .animation(reduceMotion ? nil : configuration.isPressed ? .linear(duration: 0.12) : ArcStyle.snappy, value: configuration.isPressed)
        }
    }
}

// Lucide-compatible 24-unit vector paths, avoiding SF Symbols' different shapes and metrics.
private struct ArcIcon: Shape {
    enum Kind { case cloud, file, text, image, archive, close, retry, check }
    let kind: Kind
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func m(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x, y: y)) }
        func l(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: CGPoint(x: x, y: y)) }
        func c(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ d: CGFloat, _ e: CGFloat) {
            p.addCurve(to: CGPoint(x: d, y: e), control1: CGPoint(x: x, y: y), control2: CGPoint(x: a, y: b))
        }
        switch kind {
        case .cloud:
            m(12,13); l(12,21)
            m(4,14.899)
            p.addRelativeArc(center: CGPoint(x: 9.002591855, y: 10.002667216), radius: 7,
                             startAngle: .degrees(135.61501251), delta: .degrees(207.760655446))
            l(17.5,8)
            p.addRelativeArc(center: CGPoint(x: 17.5, y: 12.5), radius: 4.5,
                             startAngle: .degrees(-90), delta: .degrees(146.251))
            m(8,17); l(12,13); l(16,17)
        case .close: m(18,6); l(6,18); m(6,6); l(18,18)
        case .check: m(4,12.5); l(9,17.5); l(20,6.5)
        case .retry:
            m(21,7); l(21,12); l(16,12)
            m(20,12); c(20,7.6,16.4,4,12,4); c(7.6,4,4,7.6,4,12); c(4,16.4,7.6,20,12,20); c(14.3,20,16.4,19,18,17.5)
        default:
            m(14,2); l(6,2); c(4.9,2,4,2.9,4,4); l(4,20); c(4,21.1,4.9,22,6,22)
            l(18,22); c(19.1,22,20,21.1,20,20); l(20,8); l(14,2); l(14,6); c(14,7.1,14.9,8,16,8); l(20,8)
            if kind == .text { m(8,13); l(16,13); m(8,17); l(16,17) }
            if kind == .image {
                p.addEllipse(in: CGRect(x: 7, y: 10, width: 3, height: 3))
                m(20,17); l(16,13); l(8,21)
            }
            if kind == .archive {
                for y in stride(from: 3, through: 13, by: 2) { m(10,CGFloat(y)); l(12,CGFloat(y)) }
                p.addRoundedRect(in: CGRect(x: 10, y: 16, width: 3, height: 4), cornerSize: CGSize(width: 1, height: 1))
            }
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).translatedBy(x: rect.minX, y: rect.minY))
    }
}

/// Matches the gallery's light preview surface. All activity here is simulated.
struct ArcFileUploadDemo: View {
    var initialFiles: [ArcUploadFile] = []
    var body: some View {
        ArcFileUploadView(label: "Upload brief", description: "PDF or markdown, up to 10 MB.",
                          acceptedTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .text],
                          maximumSize: 10 * 1024 * 1024, onUpload: Self.simulate, files: initialFiles)
            .frame(maxWidth: 480).padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ArcStyle.neutral(0.978)).preferredColorScheme(.light)
    }
    @MainActor private static func simulate(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(130))
            try Task.checkCancellation()
            progress(Double(step) * 5)
        }
    }
    static let sampleFiles: [ArcUploadFile] = [
        .init(url: URL(fileURLWithPath: "/Brand guidelines.pdf"), bytes: 2516582, phase: .done, progress: 100),
        .init(url: URL(fileURLWithPath: "/Creative brief.md"), bytes: 18432, phase: .uploading, progress: 65),
        .init(url: URL(fileURLWithPath: "/Campaign notes.pdf"), bytes: 943718, phase: .failed, progress: 45),
        .init(url: URL(fileURLWithPath: "/Archive.zip"), bytes: 4194304, error: "This file type is not accepted.")
    ]
}

#if UIARC_FILE_UPLOAD_DEMO
@main
struct ArcFileUploadDemoApp: App {
    var body: some Scene {
        WindowGroup("File upload · SwiftUI study") {
            ArcFileUploadDemo(initialFiles: CommandLine.arguments.contains("--states") ? ArcFileUploadDemo.sampleFiles : [])
                .frame(minWidth: 380, minHeight: 360)
        }.defaultSize(width: 600, height: 520)
    }
}
#endif

#Preview("Reference · empty", traits: .fixedLayout(width: 600, height: 480)) { ArcFileUploadDemo() }
#Preview("Reference · upload states", traits: .fixedLayout(width: 600, height: 600)) {
    ArcFileUploadDemo(initialFiles: ArcFileUploadDemo.sampleFiles)
}
