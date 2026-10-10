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
    /// Agent Mesh (board E): the mobile projection of a living graph —
    /// structure = declaration expansion, activity = ledger route_decision
    /// replay. Failure does not drag down the old structure (on failure it
    /// falls back to the Profile card flow).
    @Published var graph: APIClient.AgentsGraph?
    /// Graph request failure flag (0930 flicker fix): distinguishes "not
    /// loaded yet" (loading) from "genuinely unobtainable" (degrade to the
    /// old card flow) — previously both shared graph==nil, so the cold-start
    /// loading window played the degraded UI first before switching away
    /// (user-reported ~500ms flash on every tab entry).
    @Published var graphFailed = false
    /// First-load-complete flag: bounds the loading state (also keeps the "no agents yet" empty state from flashing on first screen).
    @Published private(set) var loadedOnce = false
    /// Artifact counts (data source for the board-06 per-profile "its artifacts" entry; same source for the mesh node chips).
    @Published var artifactCounts: [String: Int] = [:]
    @Published var errorMessage: String?
    private var pollTask: Task<Void, Never>?

    // Display-only dual attribution, mirroring the desktop Agents panel:
    // name namespace (profile / profile-N clone) OR the pane's classified project.
    // 2026-09-20 duplicate-card fix: the prefix rule was tightened to a
    // "numeric-suffix clone" — profiles are 1:1 session derivatives; a naming
    // prefix like juli-demo-card is not a clone, and the loose prefix once
    // attached juli-dev-2 to its parent card while also giving it its own card
    // (user-reported duplication).
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

    /// Root card list (board 06): clone sessions (base-N) attach only to the
    /// main card and never stand alone — juli-dev-2 belongs to juli-dev's card
    /// and has no Profile of its own.
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
    /// Agents→Flow seam: "what is this agent doing" answered without hunting the list.
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
        // Pull artifact counts on entry (then every 60s; see refresh).
        lastArtifactFetch = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(forceArtifactRefresh: false)
                // 5s: offset from the server's 3s tmux TTL (4s once hit for real every cycle).
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    private var lastArtifactFetch: Date?

    /// forceArtifactRefresh=false is only for polling (artifact counts
    /// throttled to 60s); explicit actions like pull-to-refresh call it with
    /// no argument and always force.
    /// 0930 parallelization: four async lets fire together — the sum of five
    /// serial hops was one of the main reasons the mesh arrived half a second
    /// late; artifact counts stay throttled and last (absence only affects the
    /// chip number; brief lag is harmless).
    func refresh(forceArtifactRefresh: Bool = true) async {
        async let profilesTask = APIClient.shared.fetchAgentProfiles()
        async let sessionsTask = APIClient.shared.fetchSessions()
        async let casesTask = APIClient.shared.fetchWorkflows()
        async let graphTask = APIClient.shared.fetchAgentsGraph()
        // Independent trys: partial failure keeps whatever arrived (same as the old behavior — early arrivals are not dragged down).
        var errs: [String] = []
        do { profiles = try await profilesTask } catch { errs.append("profiles: \(error.localizedDescription)") }
        do { sessions = try await sessionsTask } catch { errs.append("sessions: \(error.localizedDescription)") }
        do { cases = try await casesTask } catch { errs.append("cases: \(error.localizedDescription)") }
        errorMessage = errs.isEmpty ? nil : errs.joined(separator: "; ")
        // Artifact counts: best effort (failure does not block the page; a
        // missing count leaves the chip icon-only, no number). Polled every
        // 60s — a full pull every cycle is pointless traffic over the frp tunnel.
        let now = Date()
        if forceArtifactRefresh || lastArtifactFetch == nil
            || now.timeIntervalSince(lastArtifactFetch!) >= 60 {
            lastArtifactFetch = now
            if let arts = try? await APIClient.shared.fetchArtifacts(session: nil) {
                artifactCounts = Dictionary(grouping: arts, by: { $0.session }).mapValues { $0.count }
            }
        }
        // graph: set the flag on failure (the view degrades to the old card
        // flow accordingly); success keeps the semantics unchanged — a
        // transient failure does not wipe the last good structure;
        // never-succeeded + failed = degrade, never-succeeded + in flight = loading.
        do {
            graph = try await graphTask
            graphFailed = false
        } catch {
            graphFailed = true
        }
        loadedOnce = true
    }

    /// Artifact count under a profile name — exact = the base-session basis,
    /// strictly consistent with the deep-link filter
    /// (ArtifactsView selectedSession == profile.name): the chip counts N,
    /// tapping in shows exactly N. Clone-session artifacts are reachable via
    /// ArtifactsView's "All" / their own session chips and are not totaled
    /// here.
    func artifactCount(for p: APIClient.AgentProfileView) -> Int? {
        artifactCounts[p.name]
    }

    /// Mesh node name = session name; artifact counts share the same source and basis (tapping into the Artifacts filter shows exactly N).
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
    // Mesh (board E): dimensions = two sorts of the same data; tapping the
    // "recent dispatch" chip lights up that run's chain on the graph
    // (replay, not judgment).
    @State private var meshDim: MeshDim = .company
    @State private var selectedRoute: APIClient.MeshRoute?

    enum MeshDim: String, CaseIterable { case company = "By company", domain = "By domain" }

    // Skills catalog (2026-10-02 retrospective phase 1): a second-layer entry
    // — a low-key footer row into a sheet, not first-layer/top-right (the UX
    // ruling that browsing surfaces carry no primary actions stands).
    @State private var showSkills = false

    struct CaseRef: Identifiable {
        let id: String
        let title: String
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // 0930 state machine settled: loading (first round in
                // flight) / empty (fetched but genuinely none) / mesh
                // (normal) / degraded (graph genuinely unobtainable) — four
                // distinct states; the old card flow is no longer treated as
                // graph's loading state (the root cause of the ~500ms flash
                // on every tab entry).
                if !vm.loadedOnce {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading topology…")
                            .font(DS.mono(12)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.profiles.isEmpty && vm.sessions.isEmpty && vm.errorMessage == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "cpu").font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text("No agents running")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Text("Agents appear here when a job reaches its execution step")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Board 06: hand-drawn card flow (white cards, corner
                    // radius 14, no system dividers) — List/DisclosureGroup
                    // is the old structure; the designed Agents home is a
                    // decision surface of one card per agent, not a
                    // settings-page tree.
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
                                // Profiles exist but the first graph fetch is in flight (an extremely short window after parallelization).
                                VStack(spacing: 10) {
                                    ProgressView()
                                    Text("Loading topology…")
                                        .font(DS.mono(12)).foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                            } else {
                                // Graph genuinely unobtainable → degrade to
                                // the old card flow (including the artifacts
                                // entry, see onOpenArtifacts below — mesh
                                // nodes carry the same chip).
                                Text("Agent profiles · declared")
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
                            // Board 06 footer discipline: navigation must be
                            // visible (navigation hidden in a long-press =
                            // nonexistent). Skills catalog entry (second
                            // layer): a low-key footer capsule, seen only at
                            // the bottom of the scroll.
                            Button {
                                showSkills = true
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack.3d.up")
                                        .font(.system(size: 10))
                                    Text("Skill catalog")
                                        .font(DS.mono(10))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(DS.Canvas.inset)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Skill catalog")
                            .padding(.bottom, 6)
                            Text("Tap a session row → terminal · tap a chip → its entity · nothing dangles")
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
                            .accessibilityLabel("Routing map")
                    }
                }
                // Settings entry = the 4th tab-bar item ⚙ (board 02); no
                // primary action top-right on this page — top-right carries
                // only the tab's own primary action, never on browsing
                // surfaces (uniform UX ruling).
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

    /// Mesh (board E): the organization section = a living-graph projection.
    /// Extracted into its own builder — the whole block inline once pushed
    /// the compiler past type-check timeout (the old large-expression pit).
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
                    // The artifact deep link uses the same mechanism as the
                    // old cards: set producer → MakroApp switches to the
                    // Artifacts tab filtered (board-06 cross-dimension chip;
                    // node name = session name for a consistent basis).
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

// Board 06 · Agent card: standing declaration (workspace/model/duty) + live
// sessions + "working on" chips (they follow the session) + artifacts entry.
// Collapsed = a one-line summary (makro / tmux / cwd · N sessions ›);
// expanded = the full declaration. White card, corner radius 14, no system
// dividers.
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
            // Header row: status dot + name + runtime + collapse chevron (whole row tappable to collapse)
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
            .accessibilityLabel(expanded ? "Collapse \(profile.name)" : "Expand \(profile.name)")

            if expanded {
                // Declaration zone: cwd · model · duty
                Text([profile.cwd, profile.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(DS.mono(11)).foregroundStyle(.tertiary).lineLimit(1)
                if let brief = profile.prompt_brief, !brief.isEmpty {
                    Text(brief).font(DS.text(13)).foregroundStyle(.secondary).lineLimit(2)
                }
                // Session rows + their own "working on" chips (board 06: chips follow the session)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sessions) { s in
                        SessionNavRow(session: s)
                        if let w = activeCase(s.name) {
                            ActiveCaseChip(workflow: w) { onOpenCase(w) }
                        }
                    }
                }
                // Artifacts entry (board 06: ▣ its artifacts · N items › → Artifacts filtered view)
                Button {
                    onOpenArtifacts(profile.name)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 10, weight: .bold))
                        Text(artifactCount.map { "Its artifacts · \($0)" } ?? "Its artifacts")
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
                .accessibilityLabel("View artifacts of \(profile.name)")
            } else {
                // Collapsed summary (board 06): one line = name · runtime · cwd · N sessions
                Text("\(profile.cwd ?? profile.name) · \(sessions.count) sessions")
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

// "Working on" chip (board 06): ⑂ + case name → Flow case detail.
private struct ActiveCaseChip: View {
    let workflow: LifecycleWorkflow
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .bold))
                Text("Working · \(workflow.title)")
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
        .accessibilityLabel("Open the running casefile \(workflow.title)")
        .padding(.leading, 12)
    }
}

// Unassigned-sessions card (board 06): same card form, title row + session rows.
private struct OrphanSessionsCard: View {
    let sessions: [Session]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unassigned sessions · \(sessions.count)")
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
// in the old Agents tab (the fragmentation this view exists to kill).
private struct SessionNavRow: View {
    let session: Session

    private var dotColor: Color {
        // working = primary orange (board E legend "orange = working", same
        // semantics as MeshNodeRow/ProfileCard); amber already means
        // "awaiting review/thinking" in DS — no double duty.
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

// MARK: - Mesh (board E · applied 2026-09-20)
// Organization section = living-graph projection: switching dimensions is a
// re-sort of the same data (the other dimension becomes node labels); clone
// attachments stay inside cards, not top level; unassigned go into a dashed
// card; tapping the "recent dispatch" chip highlights that run's chain.
// The view owns zero state of its own — everything comes from
// /api/agents/graph.

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
                // Name the outer dom explicitly: the inner closure's $0 is a
                // MeshNode and once shadowed the outer $0, degrading the
                // comparison to node.domain == node.name (domain subgroups
                // always empty).
                .map { dom in (dom.name, mine.filter { $0.domain == dom.name }) }
                .filter { !$0.1.isEmpty }
            let rest = mine.filter { n in !doms.contains { $0.0 == (n.domain ?? "") } }
            if !rest.isEmpty { doms.append(("No domain", rest)) }
            return MeshGroup(title: company, subtitle: "\(mine.count) sessions", domains: doms)
        }
    }
    let byDomain = Dictionary(grouping: tops.filter { !($0.domain ?? "").isEmpty }, by: { $0.domain ?? "" })
    var groups = g.domains.map(\.name).filter { byDomain[$0] != nil }.map { name in
        let nodes = (byDomain[name] ?? []).sorted { $0.name < $1.name }
        return MeshGroup(title: name, subtitle: "\(nodes.count)", domains: [(name, nodes)])
    }
    // P2⑤: nodes with a company but no domain must not vanish when switching dimensions — they land in an "unassigned domain" group.
    let rest = tops.filter { ($0.domain ?? "").isEmpty }
    if !rest.isEmpty {
        groups.append(MeshGroup(title: "No domain", subtitle: "\(rest.count)", domains: [("No domain", rest.sorted { $0.name < $1.name })]))
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
                Text("Recent dispatches")
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
                    .accessibilityLabel("Replay dispatch \(label(r))")
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
            .accessibilityLabel("\(group.title) \(expanded ? "Collapse" : "Expand")")
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
                        // Two-column node cards (2026-10-03 user directive,
                        // same as the Workflow/Artifacts two-column final):
                        // nothing lost, one size smaller into half-width
                        // cards.
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
                // ① Top row: status dot + name + artifacts chip (right)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7).breathing(working)
                    Text(node.name).font(DS.mono(12.5, .semibold)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    // Artifacts chip (board 06 Feature folded into Mesh,
                    // 0930): ▣ + count, tap = deep link to the Artifacts
                    // filtered view (MakroApp switches tabs); if the count is
                    // missing (60s throttle window / fetch failure) the icon
                    // shows alone. An independent Button nested inside a
                    // NavigationLink, same as the "working on" chip — it does
                    // not hijack the row tap into the terminal.
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
                    .accessibilityLabel("View artifacts of \(node.name)")
                }
                // ② Label row: bound / default / company / clone count — a
                // standing placeholder keeps the row height
                // (wf_66a9b632154d aside: two cards in one row with mismatched
                // heights = conditionally-rendered collapsed rows, user
                // directive).
                HStack(spacing: 4) {
                    if node.isBound {
                        meshTag("bound", tint: DS.Ink.mint)
                    }
                    if node.name == graph.defaultSession {
                        meshTag("default", tint: DS.Ink.zinc)
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
                // ③ "Working on" chip (own row; at half width it no longer
                // fights the name for space) — a standing container keeps the
                // row height (wf_66a9b632154d aside: uniform card heights).
                Group {
                  if let w = activeCase {
                    Button { onOpenCase(w) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("Working · \(w.title)").lineLimit(1).truncationMode(.middle)
                        }
                        .font(DS.mono(10, .semibold))
                        .foregroundStyle(DS.Ink.mintDeep)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Ink.mint.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the running casefile \(w.title)")
                  }
                }
                .frame(minHeight: 24, alignment: .leading) // standing row height, same trick as the label row to stay even
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
        .accessibilityLabel("Session \(node.name)")
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
            Text("Unassigned · \(nodes.count)    declare them to enter the graph (config.agents)")
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
    /// Domain name → any company declaring it (for group hot-highlight; for same-name domains across companies the first declaration wins).
    func companyOf(dom: String) -> String? {
        domains.first { $0.name == dom }?.company
    }
}

// MARK: - Skills catalog (Agents page second-layer sheet, 2026-10-02 retrospective phase 1) ─────────────
// Data = GET /api/skills: family grouping (own family first) + purpose +
// dispatch health + skill_used usage aggregation. uses=0 honestly shows
// "never called" — a truthful supply-side view, no fabrication.

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
                        Text("Failed to load skill catalog")
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
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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

    /// The server already sorts by family order (juli→tool) + usage; here we only group by family (keeping section order).
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
        case "juli": return "Juli family"
        case "client": return "Client"
        case "makro": return "Makro family"
        default: return "General tools"
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
                    Text("Resident")
                        .font(DS.mono(9)).foregroundStyle(DS.Ink.slate)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.Ink.slate.opacity(0.1))
                        .clipShape(Capsule())
                }
                Spacer()
                // Dispatch health: four resolved targets out of alignment = warning color (the early-warning surface for orphaned-target incidents).
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
                    Label("called \(skill.uses)×", systemImage: "bolt.horizontal")
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
                    Text(skill.resident ? "Loaded with every task card (not a call)" : "Not called yet")
                        .font(DS.mono(10)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}
