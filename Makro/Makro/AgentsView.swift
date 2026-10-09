import SwiftUI

// Agents tab: ONE entity, ONE home. A coding agent = an agent profile (the
// standing declaration: workspace, model, brief) + its live tmux session(s).
// This view used to be a metadata-only list while sessions lived in a
// separate Terminal tab — the same entity split in two. Now the row IS the
// agent (profile info + live status) and tapping a session lands in the
// terminal detail (live pane + input) — metadata and interaction in one place.

@MainActor
final class AgentsViewModel: ObservableObject {
    @Published var profiles: [APIClient.AgentProfileView] = []
    @Published var sessions: [Session] = []
    @Published var cases: [LifecycleWorkflow] = []
    /// Agent Mesh（板E）：一张活图的移动投影——结构=声明展开，活动=账本
    /// route_decision 回放。失败不拖垮旧结构（失败时回落 Profile 卡流）。
    @Published var graph: APIClient.AgentsGraph?
    /// graph 请求失败旗（0930 闪烁修复）：区分「还没加载到」（loading）与
    /// 「确实拉不到」（降级老卡流）——此前两者共用 graph==nil，冷启动加载
    /// 窗口会把降级 UI 先演一遍再切走（用户实报每次进 tab 闪 ~500ms）。
    @Published var graphFailed = false
    /// 首轮加载完成旗：loading 态的边界（也挡住「暂无 agent」空态在首屏闪现）。
    @Published private(set) var loadedOnce = false
    /// 产物计数（板 06 per-profile「它的产物」入口的数据源；mesh 节点芯片同源）。
    @Published var artifactCounts: [String: Int] = [:]
    @Published var errorMessage: String?
    private var pollTask: Task<Void, Never>?

    // Display-only dual attribution, mirroring the desktop Agents panel:
    // name namespace (profile / profile-N clone) OR the pane's classified project.
    // 2026-09-20 重复卡修复：前缀规则收紧为「数字后缀克隆」——profiles 是
    // 会话 1:1 派生，juli-demo-card 这类命名前缀不是克隆，宽前缀曾把
    // juli-dev-2 同时挂进父卡又独立成卡（用户实报重复）。
    static func isClone(_ name: String, of base: String) -> Bool {
        guard name.hasPrefix(base + "-") else { return false }
        let suffix = String(name.dropFirst(base.count + 1))
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    static func owns(_ p: APIClient.AgentProfileView, session s: Session) -> Bool {
        let key = p.project ?? p.name
        if s.name == p.name { return true }
        if isClone(s.name, of: p.name) { return true }
        return s.project != nil && s.project == key
    }

    /// 根卡列表（板 06）：克隆会话（base-N）只挂主卡，不独立成卡——
    /// juli-dev-2 属于 juli-dev 的卡，自身不再有 Profile。
    var rootProfiles: [APIClient.AgentProfileView] {
        profiles.filter { p in
            !profiles.contains { q in q.name != p.name && Self.isClone(p.name, of: q.name) }
        }
    }

    var orphanSessions: [Session] {
        sessions.filter { s in !profiles.contains { Self.owns($0, session: s) } }
    }

    func sessions(for p: APIClient.AgentProfileView) -> [Session] {
        sessions.filter { Self.owns(p, session: $0) }
    }

    /// The live case (running/waiting) dispatched to this session — the
    /// Agents→Flow seam: "这个小张在干嘛" answered without hunting the list.
    func activeCase(for session: String) -> LifecycleWorkflow? {
        cases.first { w in
            ["running", "waiting_human"].contains(w.status)
                && (w.meta?["assigned_session"]?.stringValue == session || w.session == session)
        }
    }

    /// Deduped active cases across a profile's sessions (a case runs in ONE
    /// session, but both the name-namespace and the pane may claim it).
    func activeCases(for sessions: [Session]) -> [LifecycleWorkflow] {
        var seen = Set<String>()
        return sessions.compactMap { activeCase(for: $0.name) }.filter { seen.insert($0.id).inserted }
    }

    func startPolling() {
        pollTask?.cancel()
        // 进场即拉产物计数（此后每 60s 一次，见 refresh）。
        lastArtifactFetch = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(forceArtifactRefresh: false)
                // 5s：与服务端 tmux TTL 3s 错开（4s 曾每圈真打）。
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    private var lastArtifactFetch: Date?

    /// forceArtifactRefresh=false 仅用于轮询（产物计数按 60s 节流）；
    /// 下拉刷新等显式动作无参调用，始终强拉。
    /// 0930 并行化：四路 async let 同发——串行五跳之和曾是 mesh 晚到半秒的
    /// 主因之一；产物计数保持节流后置（缺席只影响芯片数字，短暂滞后无害）。
    func refresh(forceArtifactRefresh: Bool = true) async {
        async let profilesTask = APIClient.shared.fetchAgentProfiles()
        async let sessionsTask = APIClient.shared.fetchSessions()
        async let casesTask = APIClient.shared.fetchWorkflows()
        async let graphTask = APIClient.shared.fetchAgentsGraph()
        // 各自 try：部分失败保留已到数据（与旧行为一致——早到的不陪葬）。
        var errs: [String] = []
        do { profiles = try await profilesTask } catch { errs.append("profiles: \(error.localizedDescription)") }
        do { sessions = try await sessionsTask } catch { errs.append("sessions: \(error.localizedDescription)") }
        do { cases = try await casesTask } catch { errs.append("cases: \(error.localizedDescription)") }
        errorMessage = errs.isEmpty ? nil : errs.joined(separator: "；")
        // 产物计数：尽力而为（失败不挡页面，计数缺席则芯片只显图标无数字）。
        // 轮询下 60s 一拉——每圈全量拉取在 frp 隧道上是无谓流量。
        let now = Date()
        if forceArtifactRefresh || lastArtifactFetch == nil
            || now.timeIntervalSince(lastArtifactFetch!) >= 60 {
            lastArtifactFetch = now
            if let arts = try? await APIClient.shared.fetchArtifacts(session: nil) {
                artifactCounts = Dictionary(grouping: arts, by: { $0.session }).mapValues { $0.count }
            }
        }
        // graph：失败置旗（视图据此降级老卡流），成功保留语义不变——瞬态
        // 失败不打没上一份好结构；从未成功+失败=降级，从未成功+在途=loading。
        do {
            graph = try await graphTask
            graphFailed = false
        } catch {
            graphFailed = true
        }
        loadedOnce = true
    }

    /// profile 名下产物数——精确=基础会话口径，与深链过滤
    /// （ArtifactsView selectedSession == profile.name）严格一致：
    /// 芯片计 N 件，点进去恰好 N 件。克隆会话产物从 ArtifactsView
    /// 「All」/各自 session 芯片可达，不在此合计。
    func artifactCount(for p: APIClient.AgentProfileView) -> Int? {
        artifactCounts[p.name]
    }

    /// mesh 节点名=会话名，产物计数同源同口径（点进 Artifacts 过滤恰好 N 件）。
    func artifactCount(forSession name: String) -> Int? {
        artifactCounts[name]
    }
}

struct AgentsView: View {
    @StateObject private var vm = AgentsViewModel()
    // The Agents→Flow seam: a working agent's case opens in the SAME detail
    // sheet Flow uses (one entity, one rendering). Its own VM instance keeps
    // the two tabs' selections independent.
    @StateObject private var caseVM = LifecycleViewModel()
    @State private var openCase: CaseRef?
    // Push path of session names → TerminalDetailView. Also the landing spot
    // for push-notification deep links (DeepLinkRouter.session).
    @State private var path: [String] = []
    // Collapsed set: a profile starts expanded; user taps to fold it.
    @State private var collapsedProfiles: Set<String> = []
    // Mesh（板E）：维度=同一份数据的两种排序；点「最近分发」chip 把该 run
    // 的链路亮在图上（回放，不判定）。
    @State private var meshDim: MeshDim = .company
    @State private var selectedRoute: APIClient.MeshRoute?

    enum MeshDim: String, CaseIterable { case company = "按公司", domain = "按业务" }

    // 技能目录（2026-10-02 追溯一期）：第二层入口——页脚低调行进 sheet，
    // 不占第一层/右上角（浏览面不放主动作的 UX 裁决不变）。
    @State private var showSkills = false

    struct CaseRef: Identifiable {
        let id: String
        let title: String
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // 0930 状态机定案：loading（首轮在途）/ 空态（拉到了但真没有）/
                // mesh（正常）/ 降级（graph 确实拉不到）——四态分明，老卡流
                // 不再被当 graph 的加载态（每次进 tab 闪 ~500ms 的根因）。
                if !vm.loadedOnce {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("连接组织图…")
                            .font(DS.mono(12)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.profiles.isEmpty && vm.sessions.isEmpty && vm.errorMessage == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "cpu").font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text("暂无执行中的 agent")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Text("业务流走到「执行」步骤时，这里会出现干活的 agent")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 板 06：自绘卡片流（白卡·圆角 14·无系统分割线）——List/
                    // DisclosureGroup 是老 structure，设计的 Agents 主页是
                    // 「一 agent 一卡」的决策面，不是设置页树。
                    ScrollView {
                        VStack(spacing: 12) {
                            if let err = vm.errorMessage {
                                Text(err).font(DS.mono(12)).foregroundStyle(DS.Ink.rose)
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DS.Ink.rose.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                            }
                            if vm.graph != nil {
                                meshSection
                            } else if !vm.graphFailed {
                                // 已有 profiles 但 graph 首拉在途（并行后窗口极短）。
                                VStack(spacing: 10) {
                                    ProgressView()
                                    Text("连接组织图…")
                                        .font(DS.mono(12)).foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                            } else {
                                // graph 确实拉不到 → 降级老卡流（含产物入口，
                                // 见下方 onOpenArtifacts——Mesh 节点也有同款芯片）。
                                Text("Agent Profiles · 常驻声明")
                                    .font(DS.mono(11, .semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(vm.rootProfiles) { p in
                                    ProfileCard(
                                        profile: p,
                                        sessions: vm.sessions(for: p),
                                        activeCase: { name in vm.activeCase(for: name) },
                                        artifactCount: vm.artifactCount(for: p),
                                        expanded: collapsedProfiles.contains(p.name) ? false : true,
                                        onToggle: { toggleCollapse(p.name) },
                                        onOpenCase: { w in
                                            openCase = CaseRef(id: w.id, title: w.title)
                                            Task { await caseVM.select(w.id) }
                                        },
                                        onOpenArtifacts: { producer in
                                            DeepLinkRouter.shared.artifactsProducer = producer
                                        }
                                    )
                                }
                                if !vm.orphanSessions.isEmpty {
                                    OrphanSessionsCard(sessions: vm.orphanSessions)
                                }
                            }
                            // 板 06 页脚纪律：导航必须可见（长按里藏导航=不存在）。
                            // 技能目录入口（第二层）：页脚低调胶囊，滚动到底才见。
                            Button {
                                showSkills = true
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack.3d.up")
                                        .font(.system(size: 10))
                                    Text("技能目录")
                                        .font(DS.mono(10))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(DS.Canvas.inset)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("技能目录")
                            .padding(.bottom, 6)
                            Text("点会话行 → 终端 · 点芯片 → 对应实体 · 无处可去的名字不存在")
                                .font(DS.mono(10)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(DS.Canvas.app.ignoresSafeArea())
            .navigationTitle("")
            .navigationDestination(for: String.self) { name in
                TerminalDetailView(sessionName: name)
            }
            .onReceive(DeepLinkRouter.shared.$session) { session in
                // @Published replays the current value to this (possibly late)
                // subscriber, so cold-start session pushes still land.
                if let session { path = [session] }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RoutingDagView()
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .accessibilityLabel("路由图")
                    }
                }
                // 设置入口 = tab 栏第 4 项 ⚙（板 02）；本页右上无主动作——
                // 右上角只放本 tab 的主动作，浏览面不放（UX 统一裁决）。
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("Agents").font(DS.display(18, .semibold)).tracking(-0.3)
                        Text("\(vm.sessions.count)")
                            .font(DS.mono(13, .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(DS.Canvas.inset).clipShape(Capsule())
                    }
                }
            }
            .pullToRefresh { await vm.refresh() }
            .sheet(item: $openCase) { ref in
                WorkflowDetailSheet(vm: caseVM, workflowID: ref.id)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showSkills) {
                SkillsListView()
            }
            .onAppear { vm.startPolling() }
            .onDisappear { vm.stopPolling() }
        }
    }

    /// Mesh（板E）：组织区=活图投影。抽成独立 builder——整块内联曾让
    /// 编译器 type-check 超时（大表达式的老坑）。
    @ViewBuilder
    private var meshSection: some View {
        if let g = vm.graph {
            MeshDimPicker(dim: $meshDim)
            if !g.recent.isEmpty {
                RecentDispatchChips(recent: g.recent, selected: $selectedRoute)
            }
            let tops = g.nodes.filter { !$0.isClone }
            let groups = meshGroups(g: g, tops: tops, dim: meshDim)
            ForEach(groups, id: \.title) { group in
                MeshGroupCard(
                    group: group,
                    graph: g,
                    hotRoute: selectedRoute,
                    showCompanyTag: meshDim == .domain,
                    sessionWorking: { name in
                        vm.sessions.first { $0.name == name }?.working ?? false
                    },
                    activeCase: { name in vm.activeCase(for: name) },
                    artifactCount: { name in vm.artifactCount(forSession: name) },
                    onOpenCase: { w in
                        openCase = CaseRef(id: w.id, title: w.title)
                        Task { await caseVM.select(w.id) }
                    },
                    // 产物深链与老卡同一机制：置 producer → MakroApp 切 Artifacts
                    // tab 过滤（板 06 跨维芯片，节点名=会话名口径一致）。
                    onOpenArtifacts: { producer in
                        DeepLinkRouter.shared.artifactsProducer = producer
                    }
                )
            }
            let unassigned = tops.filter { ($0.company ?? "").isEmpty }
            if !unassigned.isEmpty {
                UnassignedNodesCard(
                    nodes: unassigned,
                    sessionWorking: { name in
                        vm.sessions.first { $0.name == name }?.working ?? false
                    }
                )
            }
        }
    }

    private func toggleCollapse(_ name: String) {
        if collapsedProfiles.contains(name) { collapsedProfiles.remove(name) }
        else { collapsedProfiles.insert(name) }
    }
}

// 板 06 · Agent 卡：常驻声明（workspace/model/职责）+ 活会话 + 正在执行
// 芯片（跟会话走）+ 产物入口。折叠态=一行摘要（makro / tmux / cwd · N 会话 ›），
// 展开态=完整声明。卡片白底圆角 14，无系统分割线。
private struct ProfileCard: View {
    let profile: APIClient.AgentProfileView
    let sessions: [Session]
    let activeCase: (String) -> LifecycleWorkflow?
    let artifactCount: Int?
    let expanded: Bool
    let onToggle: () -> Void
    let onOpenCase: (LifecycleWorkflow) -> Void
    let onOpenArtifacts: (String) -> Void

    private var dotColor: Color {
        if sessions.contains(where: { $0.working }) { return DS.Ink.mint }
        return sessions.isEmpty ? DS.Ink.zinc : DS.Ink.done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头行：状态点 + 名字 + runtime + 折叠箭头（整行可点折叠）
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor)
                        .frame(width: 7, height: 7)
                        .breathing(sessions.contains(where: { $0.working }))
                    Text(profile.name).font(DS.cardTitle())
                    runtimeChip
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "折叠 \(profile.name)" : "展开 \(profile.name)")

            if expanded {
                // 声明区：cwd · model · 职责
                Text([profile.cwd, profile.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(DS.mono(11)).foregroundStyle(.tertiary).lineLimit(1)
                if let brief = profile.prompt_brief, !brief.isEmpty {
                    Text(brief).font(DS.text(13)).foregroundStyle(.secondary).lineLimit(2)
                }
                // 会话行 + 各自的「正在执行」芯片（板 06：芯片跟会话走）
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sessions) { s in
                        SessionNavRow(session: s)
                        if let w = activeCase(s.name) {
                            ActiveCaseChip(workflow: w) { onOpenCase(w) }
                        }
                    }
                }
                // 产物入口（板 06：▣ 它的产物 · N 件 › → Artifacts 过滤视图）
                Button {
                    onOpenArtifacts(profile.name)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 10, weight: .bold))
                        Text(artifactCount.map { "它的产物 · \($0) 件" } ?? "它的产物")
                            .font(DS.mono(11, .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(DS.Ink.done)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(DS.Ink.done.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(profile.name) 的产物")
            } else {
                // 折叠摘要（板 06）：一行 = 名 · runtime · cwd · N 会话
                Text("\(profile.cwd ?? profile.name) · \(sessions.count) 会话")
                    .font(DS.mono(11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(14)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
    }

    private var runtimeChip: some View {
        Text(profile.runtime ?? "tmux")
            .font(DS.mono(10))
            .foregroundStyle(Color(red: 0.290, green: 0.420, blue: 0.604))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(red: 0.910, green: 0.933, blue: 0.969))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// 正在执行芯片（板 06）：⑂ + 案卷名 → Flow 案卷详情。
private struct ActiveCaseChip: View {
    let workflow: LifecycleWorkflow
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .bold))
                Text("正在执行 · \(workflow.title)")
                    .font(DS.mono(11, .semibold)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(DS.Ink.mint)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(DS.Ink.mint.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开正在执行的案卷 \(workflow.title)")
        .padding(.leading, 12)
    }
}

// 未归属会话卡（板 06）：同款卡片形态，标题行 + 会话行。
private struct OrphanSessionsCard: View {
    let sessions: [Session]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未归属会话 · \(sessions.count)")
                .font(DS.mono(11, .semibold)).foregroundStyle(.secondary)
            ForEach(sessions) { s in
                SessionNavRow(session: s)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
    }
}

// A tappable session line — the counterpart that used to be display-only
// in the old Agents tab (the "割裂" this view exists to kill).
private struct SessionNavRow: View {
    let session: Session

    private var dotColor: Color {
        // working=主橘（板E 图例「橘=干活」，与 MeshNodeRow/ProfileCard 同语义）；
        // amber 在 DS 里语义是「待审/thinking」，不再双占。
        if session.working { return DS.Ink.mint }
        return session.agent.isEmpty && !session.active ? Color.secondary : DS.Ink.done
    }

    var body: some View {
        NavigationLink(value: session.name) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .breathing(session.working)
                Text(session.name).font(DS.mono(12)).lineLimit(1)
                Text(session.agent.isEmpty ? "shell" : session.agent)
                    .font(DS.mono(9, .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(session.agent.isEmpty ? Color.secondary : DS.Ink.done)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((session.agent.isEmpty ? Color.secondary : DS.Ink.done).opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                if session.unread > 0 {
                    UnreadBadge(count: session.unread)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Mesh（板E · 2026-09-20 apply）
// 组织区=活图投影：维度切换是同一份数据重排（另一维变成节点标签），
// 克隆挂卡不占顶层，未归属进虚线卡；点「最近分发」chip 高亮该 run 链路。
// 视图零自有状态——全部来自 /api/agents/graph。

private struct MeshGroup {
    let title: String
    let subtitle: String
    let domains: [(name: String, nodes: [APIClient.MeshNode])]
}

private func meshGroups(g: APIClient.AgentsGraph, tops: [APIClient.MeshNode], dim: AgentsView.MeshDim) -> [MeshGroup] {
    if dim == .company {
        return g.companies.compactMap { company in
            let mine = tops.filter { $0.company == company }
            guard !mine.isEmpty else { return nil }
            var doms: [(String, [APIClient.MeshNode])] = g.domains
                .filter { $0.company == company }
                // 外层显式命名 dom：内层闭包的 $0 是 MeshNode，曾遮蔽外层
                // $0 使比较退化为 node.domain == node.name（业务子分组恒空）。
                .map { dom in (dom.name, mine.filter { $0.domain == dom.name }) }
                .filter { !$0.1.isEmpty }
            let rest = mine.filter { n in !doms.contains { $0.0 == (n.domain ?? "") } }
            if !rest.isEmpty { doms.append(("未分业务", rest)) }
            return MeshGroup(title: company, subtitle: "\(mine.count) 会话", domains: doms)
        }
    }
    let byDomain = Dictionary(grouping: tops.filter { !($0.domain ?? "").isEmpty }, by: { $0.domain ?? "" })
    var groups = g.domains.map(\.name).filter { byDomain[$0] != nil }.map { name in
        let nodes = (byDomain[name] ?? []).sorted { $0.name < $1.name }
        return MeshGroup(title: name, subtitle: "\(nodes.count)", domains: [(name, nodes)])
    }
    // P2⑤：有公司无业务的节点不能因切维度消失——落「未分业务」组。
    let rest = tops.filter { ($0.domain ?? "").isEmpty }
    if !rest.isEmpty {
        groups.append(MeshGroup(title: "未分业务", subtitle: "\(rest.count)", domains: [("未分业务", rest.sorted { $0.name < $1.name })]))
    }
    return groups
}

private struct MeshDimPicker: View {
    @Binding var dim: AgentsView.MeshDim
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AgentsView.MeshDim.allCases, id: \.self) { d in
                Button {
                    withAnimation(DS.snappy) { dim = d }
                } label: {
                    Text(d.rawValue)
                        .font(DS.text(13, dim == d ? .semibold : .regular))
                        .foregroundStyle(dim == d ? DS.Ink.mintDeep : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(dim == d ? DS.Canvas.card : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.Canvas.inset)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RecentDispatchChips: View {
    let recent: [APIClient.MeshRoute]
    @Binding var selected: APIClient.MeshRoute?

    private func label(_ r: APIClient.MeshRoute) -> String {
        let time = r.ts.count >= 16 ? String(r.ts.dropFirst(11).prefix(5)) : r.ts
        let who = r.from?.split(separator: "@").first.map(String.init) ?? "?"
        return "\(time) \(who)→\(r.session ?? "?")\(r.fallback == true ? " ⚠" : "")"
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("最近分发")
                    .font(DS.mono(10)).foregroundStyle(.tertiary)
                ForEach(recent) { r in
                    Button {
                        selected = selected?.id == r.id ? nil : r
                    } label: {
                        Text(label(r))
                            .font(DS.mono(10, .semibold))
                            .foregroundStyle(
                                selected?.id == r.id ? DS.Ink.mintDeep
                                : r.fallback == true ? DS.Ink.amber : Color.secondary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(
                                selected?.id == r.id ? DS.Ink.mint.opacity(0.14)
                                : r.fallback == true ? DS.Ink.amber.opacity(0.10) : DS.Canvas.inset)
                            .overlay(
                                RoundedRectangle(cornerRadius: 13)
                                    .stroke(selected?.id == r.id ? DS.Ink.mint : Color.clear, lineWidth: 1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回放分发 \(label(r))")
                }
            }
        }
    }
}

private struct MeshGroupCard: View {
    let group: MeshGroup
    let graph: APIClient.AgentsGraph
    let hotRoute: APIClient.MeshRoute?
    let showCompanyTag: Bool
    let sessionWorking: (String) -> Bool
    let activeCase: (String) -> LifecycleWorkflow?
    let artifactCount: (String) -> Int?
    let onOpenCase: (LifecycleWorkflow) -> Void
    let onOpenArtifacts: (String) -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(DS.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(DS.Ink.mint)
                        .frame(width: 8, height: 8)
                        .breathing(hotRoute?.company == group.title)
                    Text(group.title)
                        .font(DS.cardTitle(16)).foregroundStyle(.primary)
                    Text(group.subtitle)
                        .font(DS.mono(10)).foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.title) \(expanded ? "折叠" : "展开")")
            if expanded {
                ForEach(group.domains, id: \.name) { dom in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1).fill(
                                (hotRoute?.domain == dom.name && hotRoute?.company == graph.companyOf(dom: dom.name))
                                    ? DS.Ink.mint : Color.secondary.opacity(0.4))
                                .frame(width: 2, height: 12)
                            Text(dom.name.uppercased())
                                .font(DS.mono(10, .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                        // 双列节点卡（2026-10-03 用户口令，照 Workflow/Artifacts
                        // 双列定稿同款）：要素不丢、缩小一档进半宽卡。
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(dom.nodes) { node in
                                MeshNodeRow(
                                    node: node,
                                    graph: graph,
                                    hot: isHot(node),
                                    showCompanyTag: showCompanyTag,
                                    working: sessionWorking(node.name),
                                    activeCase: activeCase(node.name),
                                    artifactCount: artifactCount(node.name),
                                    onOpenCase: onOpenCase,
                                    onOpenArtifacts: onOpenArtifacts
                                )
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .padding(14)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
    }

    private func isHot(_ node: APIClient.MeshNode) -> Bool {
        guard let r = hotRoute else { return false }
        return node.name == r.session
            || (node.company == r.company && node.domain == r.domain)
    }
}

private struct MeshNodeRow: View {
    let node: APIClient.MeshNode
    let graph: APIClient.AgentsGraph
    let hot: Bool
    let showCompanyTag: Bool
    let working: Bool
    let activeCase: LifecycleWorkflow?
    let artifactCount: Int?
    let onOpenCase: (LifecycleWorkflow) -> Void
    let onOpenArtifacts: (String) -> Void

    private var clones: Int { graph.nodes.filter { $0.clone_of == node.name }.count }
    private var dotColor: Color { working ? DS.Ink.mint : DS.Ink.zinc }

    var body: some View {
        NavigationLink(value: node.name) {
            VStack(alignment: .leading, spacing: 6) {
                // ① 顶行：状态点 + 名字 + 产物芯片（右）
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7).breathing(working)
                    Text(node.name).font(DS.mono(12.5, .semibold)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    // 产物芯片（板 06 Feature 收编进 Mesh，0930）：▣ + 计数，
                    // 点=深链 Artifacts 过滤视图（MakroApp 切 tab）；计数缺席
                    // （60s 节流窗口/拉取失败）只显图标。嵌在 NavigationLink
                    // 内的独立按钮，与「正在执行」芯片同款——不劫持点行进终端。
                    Button { onOpenArtifacts(node.name) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 9, weight: .bold))
                            if let n = artifactCount {
                                Text("\(n)").font(DS.mono(10, .semibold))
                            }
                        }
                        .foregroundStyle(DS.Ink.done)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.Ink.done.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看 \(node.name) 的产物")
                }
                // ② 标签行：绑定 / 默认 / 公司 / 克隆数——常驻占位保行高
                //（wf_66a9b632154d 顺带：同行两卡高度不齐=条件渲染塌行，用户口令）。
                HStack(spacing: 4) {
                    if node.isBound {
                        meshTag("绑定", tint: DS.Ink.mint)
                    }
                    if node.name == graph.defaultSession {
                        meshTag("默认", tint: DS.Ink.zinc)
                    }
                    if showCompanyTag, let c = node.company, !c.isEmpty {
                        meshTag(c, tint: DS.Ink.amber)
                    }
                    if clones > 0 {
                        Text("×\(clones)").font(DS.mono(9)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 18, alignment: .leading)
                // ③ 正在执行芯片（独占一行，半宽下不再与名字抢位）——
                // 常驻容器保行高（wf_66a9b632154d 顺带：卡片高度整齐化）。
                Group {
                  if let w = activeCase {
                    Button { onOpenCase(w) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("正在执行 · \(w.title)").lineLimit(1).truncationMode(.middle)
                        }
                        .font(DS.mono(10, .semibold))
                        .foregroundStyle(DS.Ink.mintDeep)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Ink.mint.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开正在执行的案卷 \(w.title)")
                  }
                }
                .frame(minHeight: 24, alignment: .leading) // 常驻行高，与标签行同法保齐
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hot ? DS.Ink.mint.opacity(0.10) : DS.Canvas.inset.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: DS.R.btn)
                    .stroke(hot ? DS.Ink.mint : Color.secondary.opacity(0.12), lineWidth: hot ? 1.5 : 0.5))
            .clipShape(RoundedRectangle(cornerRadius: DS.R.btn, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("会话 \(node.name)")
    }

    private func meshTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(DS.mono(9, .semibold))
            .foregroundStyle(tint == DS.Ink.zinc ? Color.secondary : tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct UnassignedNodesCard: View {
    let nodes: [APIClient.MeshNode]
    let sessionWorking: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未归属 · \(nodes.count)    进图先声明（config.agents）")
                .font(DS.mono(10)).foregroundStyle(.tertiary)
            ForEach(nodes) { node in
                NavigationLink(value: node.name) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(sessionWorking(node.name) ? DS.Ink.mint : DS.Ink.zinc)
                            .frame(width: 6, height: 6)
                            .breathing(sessionWorking(node.name))
                        Text(node.name).font(DS.mono(12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(DS.Canvas.card.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.md)
                .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
    }
}

extension APIClient.AgentsGraph {
    /// 域名→任一声明它的公司（分组热高亮用；跨公司同名域取第一个声明）。
    func companyOf(dom: String) -> String? {
        domains.first { $0.name == dom }?.company
    }
}

// MARK: - 技能目录（Agents 页第二层 sheet，2026-10-02 追溯一期）─────────────
// 数据 = GET /api/skills：家族分组（自家在前）+ 用途 + 分发健康 + skill_used
// 用量聚合。uses=0 如实显示「尚未被调用」——供给面真实口径，不伪造。

struct SkillsListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var skills: [SkillInfo] = []
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if skills.isEmpty && loadFailed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 26))
                            .foregroundStyle(DS.Ink.amber)
                        Text("技能目录加载失败")
                            .font(DS.text(13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(familySections(), id: \.family) { section in
                            Section {
                                ForEach(section.items) { SkillRow(skill: $0) }
                            } header: {
                                Text(familyLabel(section.family))
                                    .font(DS.mono(11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(DS.Canvas.app.ignoresSafeArea())
                }
            }
            .navigationTitle("技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            skills = try await APIClient.shared.fetchSkills()
        } catch {
            loadFailed = true
        }
    }

    private struct FamilySection {
        let family: String
        var items: [SkillInfo]
    }

    /// 服务端已按 家族序(juli→tool)+用量序 排好；此处只按家族分组（保持段序）。
    private func familySections() -> [FamilySection] {
        var out: [FamilySection] = []
        for s in skills {
            if out.last?.family == s.family { out[out.count - 1].items.append(s) }
            else { out.append(FamilySection(family: s.family, items: [s])) }
        }
        return out
    }

    private func familyLabel(_ f: String) -> String {
        switch f {
        case "juli": return "橘粒 · juli 系"
        case "client": return "Client"
        case "makro": return "Makro 系"
        default: return "通用工具"
        }
    }
}

private struct SkillRow: View {
    let skill: SkillInfo

    private var familyColor: Color {
        switch skill.family {
        case "juli": return DS.Ink.mint
        case "client": return DS.Ink.done
        case "makro": return DS.Ink.amber
        default: return DS.Ink.zinc
        }
    }

    private var usedAgo: String? {
        guard skill.lastUsedAt > 0 else { return nil }
        let d = Date(timeIntervalSince1970: TimeInterval(skill.lastUsedAt))
        return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .font(DS.mono(13, .semibold))
                    .foregroundStyle(.primary)
                Text(skill.family)
                    .font(DS.mono(9)).foregroundStyle(familyColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(familyColor.opacity(0.1))
                    .clipShape(Capsule())
                if skill.resident {
                    Text("常驻")
                        .font(DS.mono(9)).foregroundStyle(DS.Ink.slate)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.Ink.slate.opacity(0.1))
                        .clipShape(Capsule())
                }
                Spacer()
                // 分发健康：四落点不齐 = 警示色（孤儿落点事故的前兆面）。
                Text("\(skill.targetsOk)/\(skill.targetsTotal)")
                    .font(DS.mono(10))
                    .foregroundStyle(skill.targetsOk == skill.targetsTotal
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(DS.Ink.amber))
            }
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(DS.text(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if skill.uses > 0 {
                    Label("调用 \(skill.uses)", systemImage: "bolt.horizontal")
                        .font(DS.mono(10)).foregroundStyle(.secondary)
                    if let ago = usedAgo {
                        Text("· \(ago)").font(DS.mono(10)).foregroundStyle(.tertiary)
                    }
                    ForEach(skill.sessions.prefix(3), id: \.session) { u in
                        Text(u.session)
                            .font(DS.mono(9)).foregroundStyle(DS.Ink.mintDeep)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(DS.Ink.mint.opacity(0.08))
                            .clipShape(Capsule())
                    }
                } else {
                    Text(skill.resident ? "每张任务卡必载（无调用语义）" : "尚未被调用")
                        .font(DS.mono(10)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}
