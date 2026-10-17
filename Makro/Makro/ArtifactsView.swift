import SwiftUI

/// Artifacts 双列卡片（2026-10-01 定稿，neo 选型方案三·全要素版）：
/// 每卡六层全要素——图标+相对时间 / 文件名两行主体 / 会话徽章+大小 /
/// 浅分隔线 / 案卷+终端芯片直接可点。原有元素一个不丢，字号整体缩一档。
/// 筛选层：搜索 + 类型 chips + 会话下拉（横滚 session chips 退役）。
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
                // 刷新按钮退役（板 02 手势统一）：下拉即刷；本页右上无主动作。
            }
            .pullToRefresh { await vm.loadArtifacts() }
            .onReceive(DeepLinkRouter.shared.$artifactsProducer) { producer in
                // 板 06 跨维芯片落地：Agents 卡的「它的产物」→ 这里按
                // producer（会话名）过滤。清掉一次性值防回头污染。
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
                Label("全部会话", systemImage: vm.selectedSession == nil ? "checkmark" : "tray.full")
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
                Text(vm.selectedSession.flatMap { "\($0)" } ?? "会话")
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
                        title: "出了点问题", sub: err)
        } else if vm.artifacts.isEmpty {
            stateVisual("doc.richtext", tint: DS.Ink.mint,
                        title: "No artifacts yet",
                        sub: "AI 生成的 HTML / 视频会出现在这里。\n默认列出所有 session。")
        } else if vm.filtered.isEmpty {
            stateVisual("magnifyingglass", tint: DS.Ink.zinc,
                        title: "无匹配结果",
                        sub: "试试其他关键字,或切换类型/会话筛选。")
        } else {
            cardGrid
        }
    }

    private var cardGrid: some View {
        // 定稿（2026-10-01）：双列卡片全要素，无时间分组——分组轴由
        // 「相对时间」在卡内表达，列表纯 mtime 倒序。
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

// MARK: - Artifact card（定稿六层：全要素·缩小一档）

private struct ArtifactCard: View {
    let artifact: Artifact
    var caseTitle: String? = nil
    var onOpenCase: (String) -> Void = { _ in }
    var onTerminal: (String) -> Void = { _ in }
    @State private var revealed = false

    private var tint: Color { artifact.isHTML ? DS.Ink.mint : DS.Ink.amber }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ① 顶行：类型图标 + 相对时间
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
            // ② 文件名两行主体（定稿核心：长名基本看全）
            Text(artifact.name)
                .font(DS.text(12.5, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            // ③④⑤ 小标签层整体退役（wf_8c1894d4bec0 用户回修：挤在一起的
            // 会话徽章/案卷芯片/终端芯片 8.5pt 小字看不出信息）——换一行看得
            // 清的「所属单」：状态色点 + 单标题（服务端 join 全文，两行可读），
            // 点行开案卷详情；无所属单（legacy）退化为大小小字。
            if let wf = artifact.workflow ?? legacyCaseRef {
                Button { onOpenCase(wf.id) } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Circle()
                            .fill(Self.statusColor(wf.status))
                            .frame(width: 7, height: 7)
                        Text(wf.title.isEmpty ? "所属单" : wf.title)
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
                .accessibilityLabel("打开所属单 \(wf.title)")
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

    /// legacy 兜底：无服务端 join 时用本地 caseTitles 映射拼 ref（id=session 即 wfId 口径）。
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

    // 定稿：相对时间——今天 HH:mm / 昨天 / 更早 MM-dd（分组退役后卡内表达时间轴）
    static func relativeTime(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "昨天" }
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

// MARK: - Skeleton card（双列占位）

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
            case .all: return "全部"
            case .html: return "网页"
            case .video: return "视频"
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
    /// 案卷标题映射：中央库把 cases/<wfId> 映射为 session=wfId——徽章显示
    /// 案卷名而非天书 id（板 08）。
    @Published private(set) var caseTitles: [String: String] = [:]

    private let api = APIClient.shared

    // Client-side filter: session menu + type chip + name search, instant (no network).
    /// searched = 会话 + 名称搜索（类型 chips 的计数基准，不受类型筛选影响）
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

    /// 类型 chips 的计数（以「会话+搜索」结果为基准，不受类型自身筛选影响）。
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
        // 板 08：wf id → 案卷标题映射（案卷名芯片的数据源）。
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
