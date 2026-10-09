import SwiftUI

// 路由 DAG · iOS 竖带投影（板 M；契约=docs/ui-redesign/routing-dag/CONTRACT.md，
// apply 2026-09-21）。竖带转轴：层=横带自上而下，与桌面同一套分层语义；语义色
// 按本端 DS 约定（working=mint 呼吸 / live=done / 落回=amber / 离线=zinc）。
// 降噪裁决（板 L）：手机一眼三件事——我的单走哪（trace 点亮）/ 谁在忙 / 什么
// 最热；边不画贝塞尔，落回与绑定以卡上徽标呈现（横列弧线是桌面形态）。

// MARK: - 数据

struct RouteEvent {
    let id: Int64
    let type: String
    let from: String?
    let session: String?
    let requested: String?
    let resolved: String?
}

enum RoutingDim: String, CaseIterable, Identifiable {
    case org, traffic, load
    var id: String { rawValue }
    var label: String {
        switch self {
        case .org: return "Structure"
        case .traffic: return "Traffic"
        case .load: return "Load"
        }
    }
}

struct DagCard: Identifiable {
    let key: String
    let name: String
    let subtitle: String
    let dot: Dot
    let count: Int
    let fallback: Int
    let bound: Bool
    let clone: Bool
    var id: String { key }
    enum Dot { case working, live, off, none }
}

struct DagBand: Identifiable {
    let key: String
    let label: String
    let items: [DagCard]
    var id: String { key }
}

// MARK: - 布局（纯函数：切维=换分层函数，与桌面 layout.ts 同语义）

enum RoutingLayout {

    static func build(graph: APIClient.AgentsGraph, events: [RouteEvent], dim: RoutingDim) -> [DagBand] {
        var sessionCounts: [String: Int] = [:]
        var senderCounts: [String: Int] = [:]
        var fallbacks: [String: Int] = [:]
        var senders: [String] = []
        for e in events {
            if e.type == "route_decision" {
                if let f = e.from {
                    senderCounts[f, default: 0] += 1
                    if !senders.contains(f) { senders.append(f) }
                }
                if let s = e.session { sessionCounts[s, default: 0] += 1 }
            } else if e.type == "route_fallback", let r = e.requested {
                fallbacks[r, default: 0] += 1
            }
        }
        let entry = DagBand(
            key: "entry", label: "Inlets — the dimension never changes this layer",
            items: senders.sorted { (senderCounts[$0] ?? 0) > (senderCounts[$1] ?? 0) }.map { email in
                DagCard(key: "e:\(email)", name: email,
                        subtitle: "\(senderCounts[email] ?? 0) decisions",
                        dot: .none, count: senderCounts[email] ?? 0,
                        fallback: 0, bound: false, clone: false)
            })
        let bases = graph.nodes.filter { $0.clone_of == nil }
        let clones = graph.nodes.filter { $0.clone_of != nil }
        func withClones(_ ordered: [APIClient.MeshNode]) -> [DagCard] {
            ordered.flatMap { base in [card(base)] + clones.filter { $0.clone_of == base.name }.map(card) }
        }
        func card(_ n: APIClient.MeshNode) -> DagCard {
            DagCard(
                key: "s:\(n.name)", name: n.name,
                subtitle: [n.company.map { "company=\($0)" }, n.domain, n.clone_of.map { "clone_of: \($0)" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                dot: n.working == true ? .working : (n.live == true ? .live : .off),
                count: sessionCounts[n.name] ?? 0,
                fallback: fallbacks[n.name] ?? 0,
                bound: n.isBound,
                clone: n.clone_of != nil)
        }
        switch dim {
        case .org:
            var items: [APIClient.MeshNode] = []
            for c in graph.companies.sorted() {
                items += bases.filter { $0.company == c }.sorted { $0.name < $1.name }
            }
            items += bases.filter { ($0.company ?? "").isEmpty }
            let companyCards = graph.companies.sorted().map {
                DagCard(key: "c:\($0)", name: $0, subtitle: "Company", dot: .none, count: 0, fallback: 0, bound: false, clone: false)
            }
            let domainCards = graph.domains.map {
                DagCard(key: "d:\($0.company)/\($0.name)", name: $0.name, subtitle: $0.company,
                        dot: .none, count: 0, fallback: 0, bound: false, clone: false)
            }
            return [entry,
                    DagBand(key: "company", label: "Company · COMPANY", items: companyCards),
                    DagBand(key: "domain", label: "Domain · DOMAIN", items: domainCards),
                    DagBand(key: "session", label: "Session · SESSION", items: withClones(items))]
        case .traffic:
            let bands: [(key: String, label: String, min: Int)] = [
                ("hot", "HOT ×40+", 40), ("mid", "MID ×10-40", 10), ("low", "LOW ×1-10", 1), ("idle", "IDLE ×0 · offline", 0),
            ]
            var out: [DagBand] = [entry]
            for b in bands {
                let matched = bases
                    .filter { s in
                        let c = sessionCounts[s.name] ?? 0
                        return bands.first(where: { c >= $0.min })?.key == b.key
                    }
                    .sorted { (sessionCounts[$0.name] ?? 0) > (sessionCounts[$1.name] ?? 0) }
                out.append(DagBand(key: b.key, label: b.label, items: withClones(matched)))
            }
            return out
        case .load:
            var out: [DagBand] = [entry]
            let labels = ["WORKING · on a job", "LIVE · idle", "Offline · no session"]
            for (i, label) in labels.enumerated() {
                let inTier = bases.filter { tier($0) == i }
                    .sorted { (sessionCounts[$0.name] ?? 0) > (sessionCounts[$1.name] ?? 0) }
                out.append(DagBand(key: "load\(i)", label: label, items: withClones(inTier)))
            }
            return out
        }
    }

    private static func tier(_ n: APIClient.MeshNode) -> Int {
        n.working == true ? 0 : (n.live == true ? 1 : 2)
    }
}

// MARK: - ViewModel

@MainActor
final class RoutingDagViewModel: ObservableObject {
    @Published var dim: RoutingDim = .org
    @Published var bands: [DagBand] = []
    @Published var traceWF: String?
    @Published var traceSessions: Set<String> = []
    /// 追踪落空提示（目标单已滚出最近分发窗口）——显式告知，不冒充真实路由。
    @Published var traceNotice: String?
    @Published var recent: [APIClient.MeshRoute] = []
    @Published var errorMessage: String?

    func load() async {
        do {
            let graph = try await APIClient.shared.fetchAgentsGraph()
            let events = try await APIClient.shared.fetchRouteEvents()
            bands = RoutingLayout.build(graph: graph, events: events, dim: dim)
            recent = graph.recent
            traceNotice = nil
            if let wf = traceWF { retrace(graph: graph, wf: wf) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDim(_ d: RoutingDim) async {
        dim = d
        await load()
    }

    func toggleTrace(_ wf: String) async {
        if traceWF == wf {
            traceWF = nil
            traceSessions = []
            traceNotice = nil
        } else {
            traceWF = wf
            traceNotice = nil
            await load()
        }
    }

    /// 该案卷真实走过的路由（Q6）：入口 + 会话点亮，其余降暗。
    private func retrace(graph: APIClient.AgentsGraph, wf: String) {
        var nodes = Set<String>()
        for r in graph.recent where r.workflow == wf {
            if let f = r.from { nodes.insert("e:\(f)") }
            if let s = r.session { nodes.insert("s:\(s)") }
        }
        if nodes.isEmpty {
            // 追踪目标不在 graph.recent（服务端仅保留最近若干条）里：退出
            // trace 态并显式提示——全图照常点亮不再是「真实路由点亮」。
            traceWF = nil
            traceSessions = []
            traceNotice = "This casefile is beyond the recent-dispatch window (only \(graph.recent.count) kept) — its real route cannot be replayed"
            return
        }
        traceSessions = nodes
    }
}

// MARK: - View

struct RoutingDagView: View {
    @StateObject private var vm = RoutingDagViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Dimension", selection: Binding(
                get: { vm.dim },
                set: { d in Task { await vm.setDim(d) } })) {
                ForEach(RoutingDim.allCases) { d in Text(d.label).tag(d) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if let err = vm.errorMessage {
                Text(err).font(DS.mono(12)).foregroundStyle(.secondary).padding()
            }
            if let notice = vm.traceNotice {
                Text(notice).font(DS.mono(12)).foregroundStyle(DS.Ink.amber).padding()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !vm.recent.isEmpty { recentStrip }
                    if vm.traceWF != nil { traceBar }
                    ForEach(vm.bands) { band in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(band.label) · \(band.items.count)")
                                .font(DS.mono(11, .medium))
                                .tracking(1.2)
                                .foregroundStyle(.tertiary)
                            if band.items.isEmpty {
                                Text("(empty)").font(DS.mono(12)).foregroundStyle(.tertiary)
                            }
                            ForEach(band.items) { cardView($0) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .background(DS.Canvas.app)
        .navigationTitle("Routing map")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    private var recentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Recent dispatches").font(DS.mono(11)).foregroundStyle(.tertiary)
                ForEach(vm.recent.prefix(8)) { r in
                    Button {
                        if let wf = r.workflow { Task { await vm.toggleTrace(wf) } }
                    } label: {
                        let on = vm.traceWF == r.workflow
                        HStack(spacing: 3) {
                            Text("\(String(r.ts.dropFirst(11).prefix(5))) \(r.from?.split(separator: "@").first.map(String.init) ?? "")→\(r.session ?? "")")
                            if r.fallback == true {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9)).foregroundStyle(DS.Ink.amber)
                            }
                        }
                            .font(DS.mono(11))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? DS.Ink.amber.opacity(0.16) : DS.Canvas.card)
                            .foregroundStyle(on ? DS.Ink.amber : .primary)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(on ? DS.Ink.amber : DS.Canvas.inset))
                    }
                }
            }
        }
    }

    private var traceBar: some View {
        HStack {
            Text("trace · \(vm.traceWF ?? "") — this job’s real route is lit, others dimmed")
                .font(DS.mono(12))
                .lineLimit(1)
            Spacer()
            Button("Done") {
                vm.traceWF = nil
                vm.traceSessions = []
                vm.traceNotice = nil
            }
            .font(DS.mono(12))
        }
        .padding(10)
        .background(DS.Ink.amber.opacity(0.12))
        .foregroundStyle(DS.Ink.amber)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
    }

    private func cardView(_ c: DagCard) -> some View {
        let traced = vm.traceSessions.isEmpty || vm.traceSessions.contains(c.key)
        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor(c.dot))
                .frame(width: 9, height: 9)
                .breathing(c.dot == .working)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(DS.mono(13, .semibold)).lineLimit(1)
                if !c.subtitle.isEmpty {
                    Text(c.subtitle).font(DS.mono(10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if c.fallback > 0 {
                Text("fallback ×\(c.fallback)")
                    .font(DS.mono(10, .semibold))
                    .foregroundStyle(DS.Ink.amber)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(DS.Ink.amber.opacity(0.12)))
            }
            if c.count > 0 {
                Text("×\(c.count)").font(DS.mono(13, .bold)).foregroundStyle(DS.Ink.mint)
            }
            if c.bound {
                Text("bound")
                    .font(DS.mono(9))
                    .foregroundStyle(DS.Ink.mint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(DS.Ink.mint.opacity(0.10)))
            }
        }
        .padding(12)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.md)
                .stroke(
                    c.clone ? DS.Ink.zinc.opacity(0.7)
                        : (!vm.traceSessions.isEmpty && traced ? DS.Ink.amber : DS.Canvas.inset),
                    style: StrokeStyle(lineWidth: 1, dash: c.clone ? [5, 4] : []))
        )
        .opacity(vm.traceSessions.isEmpty || traced ? 1 : 0.25)
    }

    private func dotColor(_ dot: DagCard.Dot) -> Color {
        switch dot {
        case .working: return DS.Ink.mint
        case .live: return DS.Ink.done
        case .off: return DS.Ink.zinc
        case .none: return .clear
        }
    }
}
