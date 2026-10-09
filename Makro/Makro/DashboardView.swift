import SwiftUI
import Charts

// Flow 侧 Dashboard（wf_e86d52c97b51，依据 wf_eadd5e140c06 调研设计）：
// A 三指标卡（今日 Token/今日 Workflow/总 Workflow，自然日口径+环比昨日）
// B 时段切换（7/30 天）→ C Token 趋势面积图（输入含 cache 桶/输出分层）
// D Workflow 按日条形 → E 分布（模型饼图 + 状态环形）→ F Skill Top10 →
// G 口径脚注。入口=Flow 页 toolbar（push，不加 tab——调研 IA 裁决）。
struct DashboardView: View {
    @State private var stats: DashboardStats?
    @State private var usage: UsageByModel?
    @State private var skills: [SkillInfo] = []
    @State private var days: Int = 7
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let err = loadError {
                    Text(err).font(DS.mono(12)).foregroundStyle(DS.Ink.rose)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Ink.rose.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                }
                if let s = stats {
                    metricRow(s)
                    if let attr = s.attribution { attributionStrip(attr) } // web 统计视图替代时新增
                    Picker("时段", selection: $days) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: days) { _ in Task { await load() } }
                    cacheRateTrend(s) // wf_5160b09e18d2：命中率趋势紧跟指标行
                    tokenTrend(s)
                    workflowTrend(s)
                    if let u = usage { distRow(s, u) }
                    if !skills.isEmpty { skillTop() }
                    footnote
                } else if loadError == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("读取统计…").font(DS.mono(12)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(DS.Canvas.app.ignoresSafeArea())
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            stats = try await APIClient.shared.fetchDashboardStats(days: days)
        } catch {
            loadError = "统计读取失败：\(error.localizedDescription)"
        }
        // 模型分布与 Skill Top 与时段无关，首次拉一次即可。
        if usage == nil, let u = try? await APIClient.shared.fetchUsageStats(hours: 24 * days) {
            usage = u
        }
        if skills.isEmpty, let sk = try? await APIClient.shared.fetchSkills() {
            skills = sk
        }
    }

    // MARK: - A 指标卡

    private func metricRow(_ s: DashboardStats) -> some View {
        HStack(spacing: 10) {
            // 第一卡（wf_66a9b632154d）：缓存命中率进第一行——z.ai 计费核对
            // 的第一眼指标（cached/input；input=0 不显）。
            metricCard(title: "今日 Token", value: fmtTokens(s.tokens.today.inputTokens + s.tokens.today.outputTokens),
                       cacheRate: cacheRateLabel(s),
                       sub: subLine(in: s.tokens.today.inputTokens, out: s.tokens.today.outputTokens,
                                    delta: delta(s.tokens.today.inputTokens + s.tokens.today.outputTokens,
                                                 s.tokens.yesterday.inputTokens + s.tokens.yesterday.outputTokens)))
            metricCard(title: "今日 Prompt", value: "\(s.tokens.today.calls)",
                       sub: "调用次数 · 计费口径")
            metricCard(title: "今日 Workflow", value: "\(s.workflows.today)",
                       sub: s.workflows.today >= s.workflows.yesterday
                         ? "↑ \(s.workflows.today - s.workflows.yesterday) vs 昨日"
                         : "↓ \(s.workflows.yesterday - s.workflows.today) vs 昨日")
            metricCard(title: "总 Workflow", value: "\(s.workflows.total)",
                       sub: "累计全部单据")
        }
    }

    // MARK: - A2 归属率（2026-10-06 web 统计视图替代时新增）：账本全量 vs
    // 单子归属量——纯单子视图的纠偏锚（总量含引擎 llm 行、无归属 CC 回合、
    // chat 等不挂单消耗）。
    private func attributionStrip(_ a: DashboardStats.Attribution) -> some View {
        let pct = a.ledger.inputTokens > 0 ? a.inputRate * 100 : 0
        return chartCard(title: "归属率 · 近 \(days) 天") {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Ink.zinc.opacity(0.18))
                        Capsule().fill(DS.Ink.mint)
                            .frame(width: min(geo.size.width, max(6, geo.size.width * CGFloat(pct / 100))))
                    }
                }
                .frame(height: 12)
                HStack(spacing: 14) {
                    Text("单子归属 \(fmtTokens(a.workflow.inputTokens)) · \(String(format: "%.0f%%", pct))")
                        .font(DS.mono(10, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                    Text("未归属 \(fmtTokens(a.unattributed.inputTokens))")
                        .font(DS.mono(10)).foregroundStyle(.tertiary)
                    Text("回合 \(a.workflow.prompts)/\(a.ledger.calls)")
                        .font(DS.mono(10)).foregroundStyle(.tertiary)
                }
                Text("总量含引擎 llm 行、无归属 CC 回合、chat 等不挂单消耗——单子口径之外的纠偏锚。")
                    .font(DS.mono(9)).foregroundStyle(.tertiary)
            }
        }
    }

    /// z.ai 口径缓存命中率（wf_66a9b632154d）：cached_tokens / input_tokens。
    private func cacheRateLabel(_ s: DashboardStats) -> String? {
        let inp = s.tokens.today.inputTokens
        guard inp > 0 else { return nil }
        return String(format: "%.1f%%", (s.tokens.today.cachedTokens ?? 0) / inp * 100) // wf_5160b09e18d2：去文字标签防窄屏截断
    }

    private func metricCard(title: String, value: String, cacheRate: String? = nil, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DS.micro(10, .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value).font(DS.mono(22, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let cacheRate {
                Text(cacheRate).font(DS.mono(10, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                    .lineLimit(1)
            }
            Text(sub).font(DS.mono(9.5, .regular)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
        .glassBorder(DS.R.md)
    }

    private func subLine(in inTok: Double, out outTok: Double, delta: Double) -> String {
        let arrow = delta >= 0 ? "↑" : "↓"
        return "输入 \(fmtTokens(inTok)) · 输出 \(fmtTokens(outTok)) · \(arrow)\(fmtTokens(abs(delta))) vs 昨日"
    }
    private func delta(_ a: Double, _ b: Double) -> Double { a - b }

    private func fmtTokens(_ v: Double) -> String {
        switch v {
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return String(format: "%.0f", v)
        }
    }

    // MARK: - C0 缓存命中率趋势（wf_5160b09e18d2）：按日 cached/input（%）。
    private func cacheRateTrend(_ s: DashboardStats) -> some View {
        chartCard(title: "缓存命中率趋势") {
            Chart(s.tokens.byDay, id: \.day) { d in
                LineMark(
                    x: .value("日期", dayStr(d.day)),
                    y: .value("命中率", d.inputTokens > 0 ? (d.cachedTokens ?? 0) / d.inputTokens * 100 : 0)
                )
                .foregroundStyle(DS.Ink.mintDeep)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("日期", dayStr(d.day)),
                    y: .value("命中率", d.inputTokens > 0 ? (d.cachedTokens ?? 0) / d.inputTokens * 100 : 0)
                )
                .foregroundStyle(LinearGradient(colors: [DS.Ink.mint.opacity(0.28), DS.Ink.mint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartLegend(position: .bottom, spacing: 14)
        }
    }

    // MARK: - C Token 趋势（输入/输出分层面积）

    private func tokenTrend(_ s: DashboardStats) -> some View {
        chartCard(title: "Token 消耗趋势") {
            Chart(s.tokens.byDay, id: \.day) { d in
                AreaMark(x: .value("日期", dayStr(d.day)), y: .value("输入(含缓存)", d.inputTokens))
                    .foregroundStyle(LinearGradient(colors: [DS.Ink.mint.opacity(0.45), DS.Ink.mint.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("日期", dayStr(d.day)), y: .value("输出", d.outputTokens))
                    .foregroundStyle(LinearGradient(colors: [DS.Ink.amber.opacity(0.5), DS.Ink.amber.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
            }
            .chartLegend(position: .bottom, spacing: 14)
        }
    }

    // MARK: - D Workflow 趋势

    private func workflowTrend(_ s: DashboardStats) -> some View {
        chartCard(title: "Workflow 趋势") {
            Chart(s.workflows.byDay, id: \.day) { d in
                BarMark(x: .value("日期", dayStr(d.day)), y: .value("单数", d.count))
                    .foregroundStyle(DS.Ink.mint.gradient)
                    .cornerRadius(3)
            }
        }
    }

    // MARK: - E 分布（模型饼 + 状态环形）

    private func distRow(_ s: DashboardStats, _ u: UsageByModel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            chartCard(title: "模型分布 · \(days == 7 ? "7" : "30") 天") {
                Chart(u.byModel.prefix(6), id: \.model) { m in
                    SectorMark(angle: .value("输入", m.inputTokens), innerRadius: .ratio(0.45))
                        .foregroundStyle(by: .value("模型", m.model))
                }
                .chartLegend(position: .bottom, spacing: 8)
            }
            chartCard(title: "状态构成") {
                Chart(s.workflows.byStatus, id: \.status) { st in
                    SectorMark(angle: .value("单数", st.count), innerRadius: .ratio(0.55))
                        .foregroundStyle(by: .value("状态", statusLabel(st.status)))
                }
                .chartLegend(position: .bottom, spacing: 8)
            }
        }
    }

    // MARK: - F Skill Top10

    private func skillTop() -> some View {
        let top = skills.filter { !$0.resident && $0.uses > 0 }.sorted { $0.uses > $1.uses }.prefix(10)
        if top.isEmpty {
            return AnyView(chartCard(title: "Skill 调用 Top") {
                Text("暂无调用（统计自 10-04 起累积）")
                    .font(DS.mono(11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            })
        }
        return AnyView(chartCard(title: "Skill 调用 Top \(top.count)") {
            Chart(Array(top.enumerated()), id: \.offset) { _, sk in
                BarMark(x: .value("次数", sk.uses), y: .value("技能", sk.name), stacking: .normalized)
                    .foregroundStyle(colorFor(family: sk.family))
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(sk.uses)").font(DS.mono(9)).foregroundStyle(.tertiary)
                    }
            }
            .chartXAxis(.hidden)
        })
    }

    // MARK: - G 脚注

    private var footnote: some View {
        Text("口径：今日=自然日（本地时区）；Token 输入含缓存命中桶（与账本一致）；Skill 统计自 2026-10-04 修复后累积。")
            .font(DS.mono(9.5, .regular)).foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    // MARK: - helpers

    private func chartCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(DS.micro(10, .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
        .glassBorder(DS.R.md)
    }

    private func dayStr(_ ymd: String) -> String {
        // "2026-10-04" → "10-04"（横轴留短）
        String(ymd.suffix(5))
    }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "running": return "进行中"
        case "queued": return "排队"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return s
        }
    }

    private func colorFor(family: String) -> Color {
        switch family {
        case "juli": return DS.Ink.mint
        case "client": return DS.Ink.amber
        case "makro": return DS.Ink.rose
        default: return DS.Ink.zinc
        }
    }
}
