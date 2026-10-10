import SwiftUI

/// Artifacts two-column cards (finalized 2026-10-01, neo's option three ·
/// full-element version): every card carries all six layers — icon +
/// relative time / two-line filename body / session badge + size / light
/// divider / case + terminal chips directly tappable. Not one original
/// element lost; one font-size step smaller overall.
/// Filter layer: search + type chips + session dropdown (the horizontally
/// scrolling session chips were retired).
/// Both filters are client-side against a single full fetch, so switching
/// is instant. Tap card to preview; chips navigate without leaving the list.
struct ArtifactsView: View {
    @StateObject private var vm = ArtifactViewModel()
    @State private var nav: [ArtifactNav] = []
    @State private var openCaseID: String?
    @StateObject private var caseVM = LifecycleViewModel()

    enum ArtifactNav: Hashable {
        case preview(String) // artifact.id
        case terminal(String)
    }
    @State private var appeared = false

    private struct CaseRef: Identifiable { let id: String }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack(path: $nav) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    filterBar
                    content
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(DS.Canvas.app.ignoresSafeArea())
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Artifacts")
                        .font(DS.display(18, .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(.primary)
                }
                // Refresh button retired (board 02 gesture unification): pull down to refresh; no primary action top-right on this page.
            }
            .pullToRefresh { await vm.loadArtifacts() }
            .onReceive(DeepLinkRouter.shared.$artifactsProducer) { producer in
                // Board 06 cross-dimension chip landed: the Agents card's
                // "its artifacts" → filtered here by producer (session name).
                // Clear the one-shot value so it cannot pollute on the way back.
                guard let producer else { return }
                vm.selectedSession = producer
                DeepLinkRouter.shared.artifactsProducer = nil
            }
                .navigationDestination(for: ArtifactNav.self) { dest in
                    switch dest {
                    case .preview(let id):
                        if let a = vm.artifacts.first(where: { $0.id == id }) {
                            ArtifactPreviewView(artifact: a)
                        }
                    case .terminal(let name): TerminalDetailView(sessionName: name)
                    }
                }
                .sheet(item: Binding(
                    get: { openCaseID.map { CaseRef(id: $0) } },
                    set: { openCaseID = $0?.id }
                )) { ref in
                    WorkflowDetailSheet(vm: caseVM, workflowID: ref.id)
                        .presentationDetents([.large])
                        .onAppear { Task { await caseVM.select(ref.id) } }
                }
            .task {
                await vm.loadArtifacts()
                withAnimation(DS.spring) { appeared = true }
            }
        }
    }

    // MARK: - Filter bar (type chips + session menu + search)

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            typeChips
            HStack(spacing: 8) {
                searchField
                sessionMenu
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .animation(DS.spring.delay(0.06), value: appeared)
    }

    private var typeChips: some View {
        HStack(spacing: 8) {
            ForEach(ArtifactViewModel.TypeFilter.allCases) { tf in
                TypeChip(
                    label: tf.label,
                    count: vm.count(for: tf),
                    selected: vm.selectedType == tf,
                    tint: tf.tint
                ) {
                    if vm.selectedType != tf { vm.selectedType = tf }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var sessionMenu: some View {
        Menu {
            Button {
                vm.selectedSession = nil
            } label: {
                Label("All sessions", systemImage: vm.selectedSession == nil ? "checkmark" : "tray.full")
            }
            ForEach(vm.sessionCounts) { sc in
                Button {
                    if vm.selectedSession != sc.name { vm.selectedSession = sc.name }
                } label: {
                    Label("\(sc.name) · \(sc.count)", systemImage: vm.selectedSession == sc.name ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13, weight: .medium))
                Text(vm.selectedSession.flatMap { "\($0)" } ?? "Session")
                    .font(DS.text(13, .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 90)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(vm.selectedSession == nil ? Color.secondary : ArtifactPalette.color(for: vm.selectedSession ?? ""))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(DS.Canvas.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
            .glassBorder(DS.R.md)
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search by name", text: $vm.searchText)
                .font(DS.text(14, .regular))
                .foregroundStyle(.primary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
        .glassBorder(DS.R.md)
        .animation(DS.snappy, value: vm.searchText.isEmpty)
    }

    // MARK: - Content switch

    @ViewBuilder private var content: some View {
        if vm.isLoading && vm.artifacts.isEmpty {
            skeletonGrid
        } else if let err = vm.error {
            stateVisual("exclamationmark.triangle", tint: DS.Ink.rose,
                        title: "Something went wrong", sub: err)
        } else if vm.artifacts.isEmpty {
            stateVisual("doc.richtext", tint: DS.Ink.mint,
                        title: "No artifacts yet",
                        sub: "AI-generated HTML and video land here.\nAll sessions listed by default.")
        } else if vm.filtered.isEmpty {
            stateVisual("magnifyingglass", tint: DS.Ink.zinc,
                        title: "No matches",
                        sub: "Try other keywords, or change the type/session filter.")
        } else {
            cardGrid
        }
    }

    private var cardGrid: some View {
        // Final (2026-10-01): two-column cards with all elements, no time
        // grouping — the time axis is expressed inside the card by "relative
        // time"; the list is purely mtime descending.
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(vm.filtered.enumerated()), id: \.element.id) { idx, a in
                ArtifactCard(
                    artifact: a,
                    caseTitle: a.workflow?.title ?? vm.caseTitles[a.session],
                    onOpenCase: { openCaseID = $0 },
                    onTerminal: { nav.append(.terminal($0)) }
                )
                .contentShape(Rectangle())
                .onTapGesture { nav.append(.preview(a.id)) }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .onAppear {
                    // Stagger reveal capped at ~8 rows so long grids don't drag.
                    withAnimation(DS.spring.delay(Double(min(idx, 16)) * 0.03)) {}
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Loading skeleton

    private var skeletonGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in ArtifactCardSkeleton() }
        }
        .padding(.top, 2)
    }

    // MARK: - State visual (empty / error / search-empty share layout)

    @ViewBuilder
    private func stateVisual(_ icon: String, tint: Color, title: String, sub: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(tint.opacity(0.08))
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(tint)
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(DS.display(16, .semibold))
                    .foregroundStyle(.primary)
                    .tracking(-0.2)
                Text(sub)
                    .font(DS.text(12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }
}

// MARK: - Type chip

private struct TypeChip: View {
    let label: String
    let count: Int
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(selected ? 1 : 0.55)
                Text(label)
                    .font(DS.text(13, .semibold))
                    .foregroundStyle(selected ? tint : .primary)
                Text("\(count)")
                    .font(DS.mono(11, .semibold))
                    .foregroundStyle(selected ? tint : .secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(selected ? tint.opacity(0.14) : DS.Canvas.card)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(selected ? 0 : 0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(PressDown())
        .animation(DS.snappy, value: selected)
    }
}

// MARK: - Artifact card (final six layers: all elements · one size smaller)

private struct ArtifactCard: View {
    let artifact: Artifact
    var caseTitle: String? = nil
    var onOpenCase: (String) -> Void = { _ in }
    var onTerminal: (String) -> Void = { _ in }
    @State private var revealed = false

    private var tint: Color { artifact.isHTML ? DS.Ink.mint : DS.Ink.amber }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ① Top row: type icon + relative time
            HStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: artifact.isHTML ? "globe" : "film")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    )
                Spacer(minLength: 0)
                Text(Self.relativeTime(artifact.mtime))
                    .font(DS.mono(9.5, .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            // ② Two-line filename body (core of the final: long names mostly fully visible)
            Text(artifact.name)
                .font(DS.text(12.5, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            // ③④⑤ The small-label layer was retired wholesale
            // (wf_8c1894d4bec0 user rework: 8.5pt session badge / case chip /
            // terminal chip crammed together carried no readable information)
            // — replaced by one readable "owning job" line: a status-colored
            // dot + the job title (full text from the server join, two
            // readable lines); tapping the row opens the case detail; without
            // an owning job (legacy) it degrades to small size text.
            if let wf = artifact.workflow ?? legacyCaseRef {
                Button { onOpenCase(wf.id) } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Circle()
                            .fill(Self.statusColor(wf.status))
                            .frame(width: 7, height: 7)
                        Text(wf.title.isEmpty ? "Job" : wf.title)
                            .font(DS.text(12, .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open job \(wf.title)")
            } else {
                Text(Self.formatSize(artifact.size))
                    .font(DS.mono(9.5, .regular))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(11)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassBorder(16)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 8)
        .onAppear {
            withAnimation(DS.spring) { revealed = true }
        }
    }

    /// Legacy fallback: without the server join, assemble the ref from the local caseTitles map (id=session, i.e. the wfId basis).
    private var legacyCaseRef: ArtifactWorkflowRef? {
        guard let t = caseTitle, !t.isEmpty else { return nil }
        return ArtifactWorkflowRef(id: artifact.session, title: t, status: "completed")
    }

    private static func statusColor(_ s: String) -> Color {
        switch s {
        case "running", "queued": return DS.Ink.mint
        case "completed": return DS.Ink.done
        case "failed": return DS.Ink.rose
        case "cancelled": return DS.Ink.zinc
        default: return DS.Ink.zinc
        }
    }

    // Final: relative time — today HH:mm / yesterday / older MM-dd (with grouping retired, the time axis lives inside the card)
    static func relativeTime(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    private static func formatSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - Skeleton card (two-column placeholder)

private struct ArtifactCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DS.Canvas.inset)
                .frame(width: 30, height: 30)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(DS.Canvas.inset)
                .frame(height: 11)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(DS.Canvas.inset)
                .frame(width: 80, height: 9)
            Spacer(minLength: 12)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(DS.Canvas.inset)
                .frame(width: 60, height: 8)
        }
        .padding(11)
        .frame(minHeight: 148, alignment: .topLeading)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassBorder(16)
        .shimmering()
    }
}

// MARK: - Session color palette (stable hash → DS 4-color palette)

private enum ArtifactPalette {
    private static let colors: [Color] = [DS.Ink.mint, DS.Ink.amber, DS.Ink.rose, DS.Ink.zinc]

    /// Stable across runs (Swift's String.hashValue is randomized per launch).
    static func color(for session: String) -> Color {
        var h = 0
        for c in session.unicodeScalars {
            h = (h &* 31) &+ Int(c.value)
        }
        return colors[abs(h % colors.count)]
    }
}

// MARK: - View model

@MainActor
final class ArtifactViewModel: ObservableObject {
    enum TypeFilter: String, CaseIterable, Identifiable {
        case all, html, video
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .html: return "Pages"
            case .video: return "Videos"
            }
        }

        var tint: Color {
            switch self {
            case .all: return .primary
            case .html: return DS.Ink.mint
            case .video: return DS.Ink.amber
            }
        }
    }

    @Published var selectedSession: String? = nil
    @Published var selectedType: TypeFilter = .all
    @Published var searchText = ""
    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    /// Case-title mapping: the hub maps cases/<wfId> to session=wfId — the
    /// badge shows the case name instead of a cryptic id (board 08).
    @Published private(set) var caseTitles: [String: String] = [:]

    private let api = APIClient.shared

    // Client-side filter: session menu + type chip + name search, instant (no network).
    /// searched = session + name search (the count basis for type chips, unaffected by the type filter)
    var searched: [Artifact] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return artifacts.filter { a in
            (selectedSession == nil || a.session == selectedSession)
                && (q.isEmpty || a.name.lowercased().contains(q))
        }
    }
    var filtered: [Artifact] {
        switch selectedType {
        case .all: return searched
        case .html: return searched.filter { $0.isHTML }
        case .video: return searched.filter { $0.isVideo }
        }
    }

    /// Counts for the type chips (based on the "session + search" result, unaffected by the chips' own filter).
    func count(for tf: TypeFilter) -> Int {
        switch tf {
        case .all: return searched.count
        case .html: return searched.filter { $0.isHTML }.count
        case .video: return searched.filter { $0.isVideo }.count
        }
    }

    var totalCount: Int { artifacts.count }
    var htmlCount: Int { artifacts.filter { $0.isHTML }.count }
    var videoCount: Int { artifacts.filter { $0.isVideo }.count }

    struct SessionCount: Identifiable { let name: String; let count: Int; var id: String { name } }
    var sessionCounts: [SessionCount] {
        let groups = Dictionary(grouping: artifacts, by: \.session)
        return groups.keys.sorted().map { SessionCount(name: $0, count: groups[$0]?.count ?? 0) }
    }

    var isAllSessions: Bool { selectedSession == nil }

    func loadArtifacts() async {
        // Board 08: wf id → case-title mapping (data source for the case-name chip).
        Task {
            if let wfs = try? await APIClient.shared.fetchWorkflows(limit: 500) {
                let map = Dictionary(uniqueKeysWithValues: wfs.map { ($0.id, $0.title) })
                await MainActor.run { caseTitles = map }
            }
        }
        isLoading = true
        error = nil
        do {
            // Always fetch ALL sessions; filtering is client-side for instant
            // chip/menu/search switching. Backend ?session= filter stays available.
            artifacts = try await api.fetchArtifacts(session: nil)
        } catch let e as APIClientError {
            self.error = e.errorDescription
            artifacts = []
        } catch {
            self.error = error.localizedDescription
            artifacts = []
        }
        isLoading = false
    }
}
