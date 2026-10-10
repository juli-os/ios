import SwiftUI
import Charts

// Flow-side Dashboard (wf_e86d52c97b51, designed from the wf_eadd5e140c06
// research):
// A three metric cards (tokens today / workflows today / total workflows,
// calendar-day basis + vs-yesterday) B period switch (7/30 days) → C token
// trend area chart (input incl. cache bucket / output layered) D workflows
// per-day bars → E distribution (model pie + status ring) → F Skill Top10 →
// G basis footnote. Entry = the Flow page toolbar (push, no extra tab — the
// research IA ruling).
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
                    if let attr = s.attribution { attributionStrip(attr) } // added when the web stats view was replaced
                    Picker("Period", selection: $days) {
                        Text("7d").tag(7)
                        Text("30d").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: days) { _ in Task { await load() } }
                    cacheRateTrend(s) // wf_5160b09e18d2: the hit-rate trend right under the metric row
                    tokenTrend(s)
                    workflowTrend(s)
                    if let u = usage { distRow(s, u) }
                    if !skills.isEmpty { skillTop() }
                    footnote
                } else if loadError == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading stats…").font(DS.mono(12)).foregroundStyle(.tertiary)
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
            loadError = "Stats failed to load: \(error.localizedDescription)"
        }
        // Model distribution and Skill Top are period-independent; one initial pull is enough.
        if usage == nil, let u = try? await APIClient.shared.fetchUsageStats(hours: 24 * days) {
            usage = u
        }
        if skills.isEmpty, let sk = try? await APIClient.shared.fetchSkills() {
            skills = sk
        }
    }

    // MARK: - A metric cards

    private func metricRow(_ s: DashboardStats) -> some View {
        HStack(spacing: 10) {
            // First card (wf_66a9b632154d): the cache hit rate joins the
            // first row — the at-a-glance metric for z.ai bill reconciliation
            // (cached/input; hidden when input=0).
            metricCard(title: "Tokens today", value: fmtTokens(s.tokens.today.inputTokens + s.tokens.today.outputTokens),
                       cacheRate: cacheRateLabel(s),
                       sub: subLine(in: s.tokens.today.inputTokens, out: s.tokens.today.outputTokens,
                                    delta: delta(s.tokens.today.inputTokens + s.tokens.today.outputTokens,
                                                 s.tokens.yesterday.inputTokens + s.tokens.yesterday.outputTokens)))
            metricCard(title: "Prompts today", value: "\(s.tokens.today.calls)",
                       sub: "call count · billing basis")
            metricCard(title: "Jobs today", value: "\(s.workflows.today)",
                       sub: s.workflows.today >= s.workflows.yesterday
                         ? "↑ \(s.workflows.today - s.workflows.yesterday) vs yesterday"
                         : "↓ \(s.workflows.yesterday - s.workflows.today) vs yesterday")
            metricCard(title: "Jobs total", value: "\(s.workflows.total)",
                       sub: "all time")
        }
    }

    // MARK: - A2 attribution rate (added 2026-10-06 with the web stats-view
    // replacement): full ledger volume vs job-attributed volume — the
    // correction anchor for a jobs-only view (the total includes engine llm
    // lines, unattributed CC turns, chat and other consumption that hangs on
    // no job).
    private func attributionStrip(_ a: DashboardStats.Attribution) -> some View {
        let pct = a.ledger.inputTokens > 0 ? a.inputRate * 100 : 0
        return chartCard(title: "Attribution · last \(days) days") {
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
                    Text("Job-attributed \(fmtTokens(a.workflow.inputTokens)) · \(String(format: "%.0f%%", pct))")
                        .font(DS.mono(10, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                    Text("Unattributed \(fmtTokens(a.unattributed.inputTokens))")
                        .font(DS.mono(10)).foregroundStyle(.tertiary)
                    Text("Turns \(a.workflow.prompts)/\(a.ledger.calls)")
                        .font(DS.mono(10)).foregroundStyle(.tertiary)
                }
                Text("The total includes engine llm rows, unattributed CC turns, chat and other spend not tied to a job — an anchor outside the per-job view.")
                    .font(DS.mono(9)).foregroundStyle(.tertiary)
            }
        }
    }

    /// z.ai-basis cache hit rate (wf_66a9b632154d): cached_tokens / input_tokens.
    private func cacheRateLabel(_ s: DashboardStats) -> String? {
        let inp = s.tokens.today.inputTokens
        guard inp > 0 else { return nil }
        return String(format: "%.1f%%", (s.tokens.today.cachedTokens ?? 0) / inp * 100) // wf_5160b09e18d2: drop the text label to avoid narrow-screen truncation
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
        return "Input \(fmtTokens(inTok)) · Output \(fmtTokens(outTok)) · \(arrow)\(fmtTokens(abs(delta))) vs yesterday"
    }
    private func delta(_ a: Double, _ b: Double) -> Double { a - b }

    private func fmtTokens(_ v: Double) -> String {
        switch v {
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return String(format: "%.0f", v)
        }
    }

    // MARK: - C0 cache hit-rate trend (wf_5160b09e18d2): daily cached/input (%).
    private func cacheRateTrend(_ s: DashboardStats) -> some View {
        chartCard(title: "Cache hit-rate trend") {
            Chart(s.tokens.byDay, id: \.day) { d in
                LineMark(
                    x: .value("Date", dayStr(d.day)),
                    y: .value("Hit rate", d.inputTokens > 0 ? (d.cachedTokens ?? 0) / d.inputTokens * 100 : 0)
                )
                .foregroundStyle(DS.Ink.mintDeep)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("Date", dayStr(d.day)),
                    y: .value("Hit rate", d.inputTokens > 0 ? (d.cachedTokens ?? 0) / d.inputTokens * 100 : 0)
                )
                .foregroundStyle(LinearGradient(colors: [DS.Ink.mint.opacity(0.28), DS.Ink.mint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartLegend(position: .bottom, spacing: 14)
        }
    }

    // MARK: - C Token trend (input/output layered area)

    private func tokenTrend(_ s: DashboardStats) -> some View {
        chartCard(title: "Token usage trend") {
            Chart(s.tokens.byDay, id: \.day) { d in
                AreaMark(x: .value("Date", dayStr(d.day)), y: .value("Input (cache incl.)", d.inputTokens))
                    .foregroundStyle(LinearGradient(colors: [DS.Ink.mint.opacity(0.45), DS.Ink.mint.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("Date", dayStr(d.day)), y: .value("Output", d.outputTokens))
                    .foregroundStyle(LinearGradient(colors: [DS.Ink.amber.opacity(0.5), DS.Ink.amber.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
            }
            .chartLegend(position: .bottom, spacing: 14)
        }
    }

    // MARK: - D Workflow trend

    private func workflowTrend(_ s: DashboardStats) -> some View {
        chartCard(title: "Job trend") {
            Chart(s.workflows.byDay, id: \.day) { d in
                BarMark(x: .value("Date", dayStr(d.day)), y: .value("Jobs", d.count))
                    .foregroundStyle(DS.Ink.mint.gradient)
                    .cornerRadius(3)
            }
        }
    }

    // MARK: - E Distribution (model pie + status ring)

    private func distRow(_ s: DashboardStats, _ u: UsageByModel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            chartCard(title: "Model mix · \(days == 7 ? "7" : "30") days") {
                Chart(u.byModel.prefix(6), id: \.model) { m in
                    SectorMark(angle: .value("Input", m.inputTokens), innerRadius: .ratio(0.45))
                        .foregroundStyle(by: .value("Model", m.model))
                }
                .chartLegend(position: .bottom, spacing: 8)
            }
            chartCard(title: "Status mix") {
                Chart(s.workflows.byStatus, id: \.status) { st in
                    SectorMark(angle: .value("Jobs", st.count), innerRadius: .ratio(0.55))
                        .foregroundStyle(by: .value("Status", statusLabel(st.status)))
                }
                .chartLegend(position: .bottom, spacing: 8)
            }
        }
    }

    // MARK: - F Skill Top10

    private func skillTop() -> some View {
        let top = skills.filter { !$0.resident && $0.uses > 0 }.sorted { $0.uses > $1.uses }.prefix(10)
        if top.isEmpty {
            return AnyView(chartCard(title: "Top skills") {
                Text("No calls yet (counted since 10-04)")
                    .font(DS.mono(11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            })
        }
        return AnyView(chartCard(title: "Top skills (\(top.count))") {
            Chart(Array(top.enumerated()), id: \.offset) { _, sk in
                BarMark(x: .value("Count", sk.uses), y: .value("Skill", sk.name), stacking: .normalized)
                    .foregroundStyle(colorFor(family: sk.family))
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(sk.uses)").font(DS.mono(9)).foregroundStyle(.tertiary)
                    }
            }
            .chartXAxis(.hidden)
        })
    }

    // MARK: - G Footnote

    private var footnote: some View {
        Text("Basis: today = calendar day (local timezone); token input includes the cache-hit bucket (ledger-consistent); skill counts accumulate since the 2026-10-04 fix.")
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
        // "2026-10-04" → "10-04" (keep the axis labels short)
        String(ymd.suffix(5))
    }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "running": return "Running"
        case "queued": return "Queued"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
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
