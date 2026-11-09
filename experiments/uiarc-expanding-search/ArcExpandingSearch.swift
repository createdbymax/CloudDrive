import SwiftUI

/// Native reference port of https://uiarc.dev/components/expanding-search.
/// Keep this source independent of the drive catalog; the production launcher adapts its motion.
struct ArcExpandingSearchItem: Identifiable, Equatable {
    let id: String
    let title: String
    var meta: String = ""
    var group: String = ""
    var symbol: String? = nil
    var keywords: [String] = []
}

struct ArcExpandingSearch: View {
    let label: String
    let items: [ArcExpandingSearchItem]
    var suggestions: [ArcExpandingSearchItem] = []
    var suggestionsLabel = "Recent"
    var placeholder: String? = nil
    var expandedWidth: CGFloat = 360
    var maxResults = 6
    var anchor: HorizontalAlignment = .trailing
    var emptyHint = "Try a shorter word or check the spelling."
    var onSelect: (ArcExpandingSearchItem) -> Void = { _ in }
    var onExpandedChange: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorScheme) private var scheme
    @FocusState private var fieldFocused: Bool
    @FocusState private var triggerFocused: Bool
    @Namespace private var selection
    @State private var expanded = false
    @State private var query = ""
    @State private var activeID: String?
    @State private var hovered = false

    private let height: CGFloat = 44
    private var foreground: Color { scheme == .dark ? Color(white: 0.95) : Color(white: 0.13) }
    private var muted: Color { scheme == .dark ? Color(white: 0.63) : Color(white: 0.48) }
    private var surface: Color { scheme == .dark ? Color(white: 0.10) : .white }
    private var raised: Color { scheme == .dark ? Color(white: 0.13) : .white }
    private var border: Color { scheme == .dark ? Color(white: 0.20) : Color(white: 0.91) }
    private var morph: Animation? { reduced ? nil : .spring(duration: 0.42, bounce: 0) }
    private var smooth: Animation? { reduced ? nil : .spring(duration: 0.4, bounce: 0) }
    private var snappy: Animation? { reduced ? nil : .spring(duration: 0.26, bounce: 0) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var found: [ArcExpandingSearchItem] {
        guard !trimmed.isEmpty else { return suggestions }
        let q = trimmed.lowercased()
        return items.enumerated().compactMap { position, item -> (ArcExpandingSearchItem, Int, Int)? in
            let title = item.title.lowercased()
            var score = -1
            if let range = title.range(of: q) {
                if range.lowerBound == title.startIndex { score = 0 }
                else { score = " -/\t\n".contains(title[title.index(before: range.lowerBound)]) ? 1 : 2 }
            } else if ([item.meta] + item.keywords).contains(where: { $0.lowercased().contains(q) }) { score = 3 }
            return score < 0 ? nil : (item, score, position)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }.prefix(max(0, maxResults)).map(\.0)
    }
    private var groups: [String] {
        guard !trimmed.isEmpty else { return suggestions.isEmpty ? [] : [suggestionsLabel] }
        var order: [String] = []
        for item in items where found.contains(where: { $0.id == item.id }) {
            if !order.contains(item.group) { order.append(item.group) }
        }
        return order
    }
    private var flat: [ArcExpandingSearchItem] {
        trimmed.isEmpty ? found : groups.flatMap { group in found.filter { $0.group == group } }
    }
    private var panelOpen: Bool { expanded && fieldFocused && (!trimmed.isEmpty || !suggestions.isEmpty) }
    private var panelHeight: CGFloat {
        found.isEmpty ? 70 : min(352, 12 + CGFloat(flat.count) * 48 + CGFloat(groups.filter { !$0.isEmpty }.count) * 29 + CGFloat(max(0, groups.count - 1)) * 4)
    }

    var body: some View {
        GeometryReader { geometry in
            let full = max(height, min(expandedWidth, geometry.size.width))
            shell(width: expanded ? full : height)
                .overlay(alignment: .top) {
                    if panelOpen {
                        results(width: full)
                            .frame(width: expanded ? full : height, height: panelHeight, alignment: .top)
                            .background(raised, in: RoundedRectangle(cornerRadius: 26))
                            .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(border) }
                            .clipShape(RoundedRectangle(cornerRadius: 26))
                            .shadow(color: .black.opacity(scheme == .dark ? 0.34 : 0.105), radius: 24, y: 20)
                            .shadow(color: .black.opacity(0.045), radius: 5, y: 3)
                            .offset(y: 52)
                            .transition(reduced ? .opacity : .modifier(active: ArcSearchUnfold(width: full, height: panelHeight, fraction: 0), identity: ArcSearchUnfold(width: full, height: panelHeight, fraction: 1)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: anchor == .leading ? .leading : .trailing)
                .animation(smooth, value: panelHeight)
                .animation(smooth, value: panelOpen)
        }
        .frame(height: height)
        .onChange(of: query) { _, _ in activeID = trimmed.isEmpty ? nil : flat.first?.id }
        .onChange(of: fieldFocused) { _, focused in if !focused && trimmed.isEmpty { collapse(returnFocus: false) } }
    }

    private func shell(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: expanded ? 18 : 22)
                .fill(hovered && !expanded ? foreground.opacity(0.035) : surface)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .frame(width: 18, height: 18).padding(.leading, 12)
                .foregroundStyle(expanded ? foreground : muted).accessibilityHidden(true)
            TextField(placeholder ?? label, text: $query)
                .textFieldStyle(.plain).font(.system(size: 14)).tracking(-0.14)
                .foregroundStyle(foreground).padding(.leading, 38).padding(.trailing, 40)
                .focused($fieldFocused).accessibilityLabel(label)
                .opacity(expanded ? 1 : 0).disabled(!expanded)
                .animation(reduced ? .linear(duration: 0.15) : .easeOut(duration: 0.2).delay(expanded ? 0.08 : 0), value: expanded)
                .onKeyPress(.escape) { collapse(returnFocus: true); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onSubmit { if let item = flat.first(where: { $0.id == activeID }) { choose(item) } }
            if !expanded {
                Button(action: expand) { Color.clear.contentShape(Circle()) }
                    .buttonStyle(.plain).focused($triggerFocused).accessibilityLabel(label)
            }
            if expanded && !query.isEmpty {
                HStack {
                    Spacer()
                    Button { query = ""; activeID = nil; fieldFocused = true } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
                    }.buttonStyle(.plain).foregroundStyle(muted).accessibilityLabel("Clear search").padding(.trailing, 7)
                }.transition(reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 18 : 22))
        .overlay { RoundedRectangle(cornerRadius: expanded ? 18 : 22).strokeBorder(fieldFocused || triggerFocused ? foreground : border) }
        .overlay { RoundedRectangle(cornerRadius: expanded ? 18 : 22).stroke(foreground.opacity(fieldFocused || triggerFocused ? 0.12 : 0), lineWidth: 3).padding(-1.5) }
        .onHover { hovered = $0 }
        .animation(snappy, value: query.isEmpty)
    }

    private func results(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if found.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No results for “\(trimmed)”").font(.system(size: 14, weight: .medium)).foregroundStyle(foreground)
                            Text(emptyHint).font(.system(size: 12)).foregroundStyle(muted)
                        }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 14)
                    } else {
                        ForEach(groups, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                if !group.isEmpty {
                                    Text(group).font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4).frame(height: 29)
                                }
                                ForEach(trimmed.isEmpty ? found : found.filter { $0.group == group }) { item in
                                    row(item).id(item.id)
                                }
                            }
                        }
                    }
                }.padding(6).frame(width: width - 2, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeID) { _, value in if let value { proxy.scrollTo(value) } }
        }
    }

    private func row(_ item: ArcExpandingSearchItem) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 12) {
                if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 16)).frame(width: 18)
                        .foregroundStyle(activeID == item.id ? foreground : muted)
                }
                VStack(alignment: .leading, spacing: 0) {
                    matched(item.title).font(.system(size: 14)).foregroundStyle(foreground).lineLimit(1)
                    if !item.meta.isEmpty { Text(item.meta).font(.system(size: 12)).foregroundStyle(muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 48)
                .background {
                    if activeID == item.id {
                        if reduced {
                            RoundedRectangle(cornerRadius: 20).fill(foreground.opacity(0.06))
                        } else {
                            RoundedRectangle(cornerRadius: 20).fill(foreground.opacity(0.06))
                                .matchedGeometryEffect(id: "active", in: selection)
                        }
                    }
                }.contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
            .onHover { inside in if inside { withAnimation(snappy) { activeID = item.id } } }
            .accessibilityAddTraits(activeID == item.id ? .isSelected : [])
    }

    private func matched(_ title: String) -> Text {
        guard !trimmed.isEmpty, let range = title.range(of: trimmed, options: .caseInsensitive) else { return Text(title) }
        return Text("\(Text(String(title[..<range.lowerBound])))\(Text(String(title[range])).fontWeight(.medium))\(Text(String(title[range.upperBound...])))")
    }
    private func expand() {
        withAnimation(morph) { expanded = true }
        fieldFocused = true
        onExpandedChange(true)
    }
    private func collapse(returnFocus: Bool) {
        guard expanded else { return }
        fieldFocused = false
        withAnimation(smooth) { expanded = false; query = ""; activeID = nil }
        if returnFocus { triggerFocused = true }
        onExpandedChange(false)
    }
    private func move(_ step: Int) {
        guard !flat.isEmpty else { return }
        let current = flat.firstIndex { $0.id == activeID }
        let next = current.map { ($0 + step + flat.count) % flat.count } ?? (step > 0 ? 0 : flat.count - 1)
        withAnimation(snappy) { activeID = flat[next].id }
    }
    private func choose(_ item: ArcExpandingSearchItem) { collapse(returnFocus: true); onSelect(item) }
}

private struct ArcSearchUnfold: ViewModifier, Animatable {
    let width: CGFloat
    let height: CGFloat
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }
    func body(content: Content) -> some View {
        content.frame(width: 44 + (width - 44) * fraction, height: height * fraction, alignment: .topLeading)
            .clipped().opacity(Double(fraction))
    }
}

#Preview("Arc expanding search") {
    ArcExpandingSearch(label: "Search projects and docs", items: [
        .init(id: "p1", title: "Arc website", meta: "Updated today", group: "Projects", symbol: "folder"),
        .init(id: "d1", title: "Motion tokens", meta: "Design system", group: "Docs", symbol: "doc.text", keywords: ["spring"])
    ], suggestions: [.init(id: "p1", title: "Arc website", meta: "Updated today", symbol: "folder")])
    .frame(width: 360).padding(40).frame(height: 420, alignment: .top).background(Color(white: 0.97))
}
