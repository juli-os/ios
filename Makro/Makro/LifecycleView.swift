import SwiftUI
import PDFKit
import QuickLook
import Charts

// V2 pipeline surface on iOS: the approval inbox first (the operator's
// primary loop is "approve things"), the workflow list + step timeline
// second. Gate pushes deep-link here via DeepLinkRouter — landing straight
// on the workflow's detail sheet, not just the tab.

/// Anything previewable by artifact id: a case artifact row or a gate
/// deliverable pointer (which carries no mime — bytes get sniffed).
struct PreviewTarget: Identifiable, Equatable {
    let id: String
    let name: String
    var mime: String?
    var bytes: Int64?

    init(id: String, name: String, mime: String? = nil, bytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.mime = mime
        self.bytes = bytes
    }

    init(_ artifact: CaseArtifact) {
        self.init(id: artifact.id, name: artifact.name, mime: artifact.mime, bytes: artifact.bytes)
    }
}

@MainActor
final class LifecycleViewModel: ObservableObject {
    @Published var gates: [GateQueueItem] = []
    @Published var workflows: [LifecycleWorkflow] = []
    @Published var selectedTree: LifecycleWorkflowTree?
    @Published var selectedID: String?
    @Published var selectedError: String?
    @Published var selectedArtifacts: [CaseArtifact] = []
    @Published var errorMessage: String?
    @Published var gateError: String?
    /// Failure reason for actions inside the detail sheet — kept separate from
    /// the polling-refreshed errorMessage; cleared only when the next action
    /// starts (otherwise the 5s poll would wipe the 400 reason in a flash).
    @Published var actionError: String?
    @Published var acting = false

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // Independent fetches: a gate-queue hiccup must not blank the
        // workflow list (and vice versa). Failures keep the last good data
        // on screen — an empty flash after every backend restart reads as
        // "broken"; stale-but-real beats blank. The gate inbox additionally
        // raises a visible error: "0 pending" and "fetch failed" must never
        // look identical on an approval surface.
        do {
            gates = try await APIClient.shared.fetchGateQueue()
            gateError = nil
        } catch {
            gateError = error.localizedDescription
        }
        do {
            workflows = try await APIClient.shared.fetchWorkflows()
            errorMessage = nil
        } catch {
            // Keep last good workflows; surface the error only if the list
            // has nothing to show.
            if workflows.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        if let id = selectedID {
            // Same policy as gates/workflows: a transient failure keeps the old data; no skeleton flash.
            if let tree = try? await APIClient.shared.fetchWorkflowTree(id) {
                selectedTree = tree
            }
            selectedArtifacts = (try? await APIClient.shared.fetchCaseArtifacts(workflowID: id)) ?? selectedArtifacts
        }
    }

    /// Per-workflow auto-approve toggle (2026-10-07): POST then re-fetch the tree to refresh the badge.
    func setAutoApprove(_ id: String, on: Bool) async throws {
        try await APIClient.shared.setAutoApprove(workflowId: id, on: on)
    }

    func reloadSelected() async {
        guard let id = selectedTree?.workflow.id else { return }
        if let tree = try? await APIClient.shared.fetchWorkflowTree(id) {
            selectedTree = tree
        }
    }

    func select(_ id: String) async {
        selectedID = id
        selectedTree = nil
        selectedArtifacts = []
        selectedError = nil
        do {
            selectedTree = try await APIClient.shared.fetchWorkflowTree(id)
            selectedError = nil
        } catch {
            selectedError = error.localizedDescription
        }
        selectedArtifacts = (try? await APIClient.shared.fetchCaseArtifacts(workflowID: id)) ?? []
    }

    func approve(_ item: GateQueueItem, note: String = "") async {
        await act(item, action: "approve", note: note)
    }

    func deny(_ item: GateQueueItem, note: String = "") async {
        await act(item, action: "deny", note: note)
    }

    /// Handled outside makro: close as cancelled, keep everything for audit.
    func resolve(_ item: GateQueueItem, note: String = "") async {
        await act(item, action: "resolve", note: note)
    }

    /// Reject & rework: the feedback re-runs the previous step; round +1.
    func rework(stepID: String, feedback: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await reworkThrowing(stepID: stepID, feedback: feedback)
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    /// Throwing form for sheets that present the error in place.
    func reworkThrowing(stepID: String, feedback: String) async throws {
        try await APIClient.shared.reworkStep(stepID: stepID, feedback: feedback)
    }

    /// Course amendment: the human's final wording wins and is filed as an amendment; the run continues.
    func align(stepID: String, amendment: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await alignThrowing(stepID: stepID, amendment: amendment)
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    func alignThrowing(stepID: String, amendment: String) async throws {
        try await APIClient.shared.alignStep(stepID: stepID, amendment: amendment)
        await refresh()
    }

    /// First-class intervene: delivered to the in-flight agent step and traced
    /// (intervention history / activity timeline / audit events). Failures are
    /// rejected (server validates agent/verify and running); the ledger only
    /// records what actually happened.
    func intervene(stepID: String, text: String) async throws {
        try await APIClient.shared.interveneStep(stepID: stepID, text: text)
        await refresh()
    }

    /// Throwing form of deny: the sheet shows the failure reason in place (server 400 body).
    func denyThrowing(_ item: GateQueueItem, note: String) async throws {
        try await APIClient.shared.gateAction(stepID: item.step.id, action: "deny", note: note)
        await refresh()
    }

    /// Force-close a running pipeline (terminal escape hatch): unlike resolve,
    /// no gate wait — any running state can be ended; in-flight steps are all
    /// cancelled and the facts stay in the ledger.
    func forceClose(_ workflowID: String, note: String) async throws {
        try await APIClient.shared.forceCloseWorkflow(workflowID, note: note)
        await refresh()
    }

    // MARK: - Case-level actions (web alignment batch 1)

    /// Settle: explicit settlement after nodes-mode actions finish.
    func settle(_ workflowID: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await APIClient.shared.settleWorkflow(workflowID)
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    /// Failed close-out: formally closes a failed case.
    func closeFailed(_ workflowID: String, note: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await APIClient.shared.closeWorkflow(workflowID, note: note)
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    /// Scheduled send: approves the send gate and schedules delivery (default tomorrow 09:00).
    func scheduleApprove(stepID: String, at date: Date) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await APIClient.shared.approveScheduled(stepID: stepID, sendAt: date,
                                                        note: "Scheduled send (iphone)")
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    /// Cancel one step: does not affect the whole job (pending/waiting are legal).
    func cancelStep(_ stepID: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await APIClient.shared.cancelStep(stepID: stepID, note: "iphone cancelled this step")
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    /// Amend & resend: the correction channel after the send guard refuses.
    func reworkSend(_ stepID: String, feedback: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await APIClient.shared.reworkSend(stepID: stepID, feedback: feedback)
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    /// Retry with new instructions: retry carrying a plan override (agent/verify steps).
    func retryWithPlan(_ stepID: String, plan: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await APIClient.shared.retryWithPatch(stepID: stepID, plan: plan)
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    func retry(stepID: String) async {
        acting = true
        actionError = nil
        defer { acting = false }
        do {
            try await APIClient.shared.gateAction(stepID: stepID, action: "retry", note: "")
            await refresh()
        } catch { actionError = error.localizedDescription }
    }

    func purgeCaseArtifacts(_ workflowID: String) async throws {
        _ = try await APIClient.shared.purgeCaseArtifacts(workflowID: workflowID)
        selectedArtifacts = (try? await APIClient.shared.fetchCaseArtifacts(workflowID: workflowID)) ?? []
    }

    private func act(_ item: GateQueueItem, action: String, note: String) {
        acting = true
        Task {
            defer { acting = false }
            do {
                try await APIClient.shared.gateAction(stepID: item.step.id, action: action, note: note)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct LifecycleView: View {
    @StateObject private var vm = LifecycleViewModel()
    @State private var appeared = false
    // Persistent stats row (wf_2efe5185faf6 three metrics → wf_66a9b632154d
    // four metrics + cache hit rate): a glance summary at the top of Flow;
    // details live in the Dashboard.
    @State private var dashTodayTokens: String = "…"
    @State private var dashTodayPrompts: String = "…"
    @State private var dashCacheRate: String?
    @State private var dashTodayWF: Int = -1
    @State private var dashTotalWF: Int = -1
    @State private var dashYesterdayWF: Int = 0
    @State private var dashYesterdayTokens: Double = 0

    private func loadHeaderStats() async {
        guard let s = try? await APIClient.shared.fetchDashboardStats(days: 1) else { return }
        dashTodayTokens = Self.fmtTokensCompact(s.tokens.today.inputTokens + s.tokens.today.outputTokens)
        dashTodayPrompts = "\(s.tokens.today.calls)"
        // z.ai billing-basis hit rate (wf_66a9b632154d): cached_tokens / input_tokens
        // (cached is a subset of input; hidden as meaningless when input=0).
        let inp = s.tokens.today.inputTokens
        let cached = s.tokens.today.cachedTokens ?? 0
        dashCacheRate = inp > 0 ? String(format: "%.1f%%", cached / inp * 100) : nil
        dashTodayWF = s.workflows.today
        dashYesterdayWF = s.workflows.yesterday
        dashTotalWF = s.workflows.total
        dashYesterdayTokens = s.tokens.yesterday.inputTokens + s.tokens.yesterday.outputTokens
    }

    static func fmtTokensCompact(_ v: Double) -> String {
        switch v {
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return String(format: "%.0f", v)
        }
    }
    // APNs gate tap lands here: workflow_id (+ optional step_id) from
    // DeepLinkRouter, consumed by opening the detail sheet directly.
    @Binding var deepLink: GateLink?
    @State private var reworkTarget: GateQueueItem?
    @State private var denyTarget: GateQueueItem?
    @State private var gatePreview: PreviewTarget?
    @State private var showComposer = false
    @State private var workbenchItem: GateQueueItem?

    init(deepLink: Binding<GateLink?> = .constant(nil)) {
        _deepLink = deepLink
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let err = vm.errorMessage {
                        ErrorBanner(text: err, tone: .rose)
                    }
                    // Approval inbox freshness: never let "fetch failed" and
                    // "nothing to approve" look the same.
                    if let gateErr = vm.gateError {
                        if vm.gates.isEmpty {
                            ErrorBanner(text: "Gate queue failed to load: \(gateErr)", tone: .rose)
                        } else {
                            ErrorBanner(text: "Gate refresh failed — showing last data (\(vm.gates.count) pending)", tone: .amber)
                        }
                    }
                    if !vm.gates.isEmpty {
                        GateQueueSection(
                            gates: vm.gates, vm: vm,
                            onRework: { reworkTarget = $0 },
                            onDeny: { denyTarget = $0 },
                            onPreview: { gatePreview = $0 },
                            onOpen: { workbenchItem = $0 }
                        )
                    }
                    headerStatsRow
                    CostAnalysisSection()
                    WorkflowListSection(workflows: vm.workflows, vm: vm)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(DS.Canvas.app.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Dashboard entry (wf_e86d52c97b51, research IA: no tab, view-only surface)
                    NavigationLink {
                        DashboardView()
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DS.Ink.mint)
                    }
                    .accessibilityLabel("Dashboard")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Intake entry (board 10): voice-first; startTask takes over upon dispatch.
                    Button {
                        showComposer = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(DS.Ink.mint)
                    }
                    .accessibilityLabel("Intake")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("Flow")
                            .font(DS.display(18, .semibold))
                            .tracking(-0.3)
                        Text("\(vm.workflows.count)")
                            .font(DS.mono(13, .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DS.Canvas.inset)
                            .clipShape(Capsule())
                    }
                }
            }
            .pullToRefresh {
                await vm.refresh()
                await loadHeaderStats()
            }
            .onAppear {
                vm.startPolling()
                Task { await loadHeaderStats() }
                guard !appeared else { return }
                appeared = true
                consumeDeepLink()
            }
            .onChange(of: deepLink) { _ in consumeDeepLink() }
            .onDisappear { vm.stopPolling() }
            .sheet(item: Binding(
                get: { vm.selectedID.map { WorkflowSheetTarget(id: $0) } },
                set: { vm.selectedID = $0?.id }
            )) { target in
                WorkflowDetailSheet(vm: vm, workflowID: target.id)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $gatePreview) { target in
                CaseArtifactPreview(target: target)
            }
            .fullScreenCover(item: $workbenchItem) { it in
                NavigationStack { GateWorkbenchView(item: it, vm: vm) }
            }
            .sheet(isPresented: $showComposer) {
                TaskComposerView { newID in
                    // Wait for the intake sheet's dismissal animation before presenting the
                    // detail (two-level presentation race on the same view).
                    Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        await vm.select(newID)
                    }
                }
            }
            // Reject offers two paths (aligned with web 8f68aba/eadbaa1 semantics):
            // rework = note injected, previous step re-runs (required, empty text
            // blocked locally); course amendment = human-final align filed, run
            // continues; force reject = terminal. An empty note is flagged locally
            // right away, without waiting for the server's 400.
            .sheet(item: $reworkTarget) { item in
                ReworkSheet(item: item, vm: vm)
                    .presentationDetents([.medium])
            }
            .confirmationDialog(
                denyTarget.map { "Reject \($0.step.displayTitle)?" } ?? "Reject?",
                isPresented: Binding(
                    get: { denyTarget != nil },
                    set: { if !$0 { denyTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Confirm rejection (terminates the run)", role: .destructive) {
                    if let item = denyTarget {
                        Task { await vm.deny(item) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The run is marked failed with the rejection reason; afterwards only a new run is possible. To give feedback and keep going, use Rework instead")
            }
        }
    }

    /// Persistent three-metric row (wf_2efe5185faf6): a glance summary at the top
    /// of Flow — same basis as the Dashboard metric cards (calendar day /
    /// cache-included input + output); tap the row to open the Dashboard.
    private var headerStatsRow: some View {
        NavigationLink {
            DashboardView()
        } label: {
            HStack(spacing: 10) {
                headerStat(title: "Tokens today", value: dashTodayTokens,
                           sub: "calendar day · cache included",
                           cacheRate: dashCacheRate)
                headerStat(title: "Prompts today", value: dashTodayPrompts,
                           sub: "call count · billing basis")
                headerStat(title: "Jobs today",
                           value: dashTodayWF < 0 ? "…" : "\(dashTodayWF)",
                           sub: dashTodayWF < 0 ? "" : wfDeltaSub)
                headerStat(title: "Jobs total",
                           value: dashTotalWF < 0 ? "…" : "\(dashTotalWF)",
                           sub: "all time")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open dashboard")
    }

    private var wfDeltaSub: String {
        let d = dashTodayWF - dashYesterdayWF
        return d >= 0 ? "↑\(d) vs yesterday" : "↓\(-d) vs yesterday"
    }

    private func headerStat(title: String, value: String, sub: String, cacheRate: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(DS.micro(9, .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value).font(DS.mono(19, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let cacheRate {
                Text(cacheRate).foregroundStyle(DS.Ink.mintDeep).lineLimit(1)
            }
            Text(sub).font(DS.mono(9, .regular)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
        .glassBorder(DS.R.md)
    }

    private func consumeDeepLink() {
        guard let link = deepLink else { return }
        deepLink = nil
        Task { await vm.select(link.workflowID) }
    }

    private struct WorkflowSheetTarget: Identifiable { let id: String }
}

/// Two-path reject panel: rework (feedback required, empty text blocked locally)
/// or course amendment (align with the human's final wording, run continues).
/// Errors show in place — no longer falling through to the list banner hidden
/// behind the sheet. Server contract (eadbaa1): empty feedback gets a 400.
struct ReworkSheet: View {
    let item: GateQueueItem
    @ObservedObject var vm: LifecycleViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var feedback = ""
    @State private var errorText: String?
    @State private var busy = false

    private var trimmed: String { feedback.trimmingCharacters(in: .whitespaces) }

    // Board 04: note card (required + counter 72/500) → three action rows → footnote.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reject \(item.step.displayTitle)")
                        .font(DS.display(16, .bold))

                    Text("What to change (required)")
                        .font(DS.mono(11, .semibold)).foregroundStyle(DS.Ink.mintDeep)

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("What should change…", text: $feedback, axis: .vertical)
                            .font(DS.text(12.5))
                            .lineLimit(4...8)
                            .padding(10)
                            .background(DS.Canvas.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        HStack {
                            Spacer()
                            Text("\(trimmed.count) / 500")
                                .font(DS.mono(9))
                                .foregroundStyle(trimmed.count > 500 ? DS.Ink.rose : Color.secondary.opacity(0.6))
                        }
                        Text("An empty note is blocked locally — reject without saying what to change and the agent has nothing to rework")
                            .font(DS.mono(9.5)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(DS.Canvas.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if let errorText {
                        Text(errorText)
                            .font(DS.mono(11)).foregroundStyle(DS.Ink.rose)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Ink.rose.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    actionRow(icon: "arrow.uturn.backward", title: "Rework",
                              subtitle: "Note injected into the previous step · round +1 · run continues",
                              fill: Color(red: 0.992, green: 0.945, blue: 0.902),
                              border: Color(red: 0.922, green: 0.835, blue: 0.737),
                              fg: DS.Ink.mintDeep) {
                        submit { try await vm.reworkThrowing(stepID: item.step.id, feedback: trimmed) }
                    }

                    actionRow(icon: "square.and.pencil", title: "Course amendment",
                              subtitle: "Your final wording is filed as an amendment · run continues",
                              fill: DS.Canvas.inset, border: Color.secondary.opacity(0.15),
                              fg: .primary) {
                        submit { try await vm.alignThrowing(stepID: item.step.id, amendment: trimmed) }
                    }

                    actionRow(icon: "xmark", title: "Force reject",
                              subtitle: "Terminates the run · finished parts stay on record",
                              fill: DS.Canvas.card,
                              border: Color(red: 0.910, green: 0.780, blue: 0.761),
                              fg: DS.Ink.rose) {
                        submit { try await vm.denyThrowing(item, note: trimmed) }
                    }

                    Text("All three actions hit the ledger (by: iphone). Use the last one only to kill the run")
                        .font(DS.mono(9.5)).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(DS.Canvas.app.ignoresSafeArea())
            .navigationTitle("Reject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String,
                           fill: Color, border: Color, fg: Color,
                           action: @escaping () -> Void) -> some View {
        Button {
            guard !trimmed.isEmpty else {
                errorText = "Note cannot be empty — reject without saying what to change and the agent has nothing to rework"
                return
            }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.text(13, .bold)).foregroundStyle(fg)
                    Text(subtitle).font(DS.mono(9.5)).foregroundStyle(fg.opacity(0.75))
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(fill)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func submit(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct ErrorBanner: View {
    let text: String
    enum Tone { case rose, amber }
    var tone: Tone = .rose

    var body: some View {
        Text(text)
            .font(DS.mono(12))
            .foregroundStyle(tone == .rose ? DS.Ink.rose : DS.Ink.amber)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Canvas.inset)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
    }
}

private struct GateQueueSection: View {
    let gates: [GateQueueItem]
    let vm: LifecycleViewModel
    let onRework: (GateQueueItem) -> Void
    let onDeny: (GateQueueItem) -> Void
    let onPreview: (PreviewTarget) -> Void
    let onOpen: (GateQueueItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(DS.Ink.amber).frame(width: 7, height: 7)
                Text("Awaiting my approval · \(gates.count)")
                    .font(DS.display(15, .semibold))
            }
            ForEach(gates) { item in
                GateCard(item: item, vm: vm, onRework: onRework, onDeny: onDeny, onPreview: onPreview, onOpen: onOpen)
            }
        }
    }
}

private struct GateCard: View {
    let item: GateQueueItem
    let vm: LifecycleViewModel
    let onRework: (GateQueueItem) -> Void
    let onDeny: (GateQueueItem) -> Void
    let onPreview: (PreviewTarget) -> Void
    let onOpen: (GateQueueItem) -> Void
    @State private var note = ""
    @State private var bodyExpanded = false

    private var checks: [GateCheck] { item.step.checkItems }
    private var checkFailed: Bool { item.step.hasFailedCheck }
    private var deliverables: [GateDeliverable] { item.step.deliverableItems }

    /// The thing being approved. Approve without content is a rubber stamp —
    /// the card must render the payload: inline body text, the body artifact
    /// (body_ref contract), and every deliverable pointer.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.step.displayTitle)
                    .font(DS.display(14, .semibold))
                Spacer()
                if let wf = item.workflow {
                    Text(wf.title)
                        .font(DS.mono(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(item) }
            // Send preflight (server-side checks): the approver must see WHY
            // approve is blocked — the server refuses approve on any fail.
            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(c.failed ? DS.Ink.rose : (c.status == "warn" ? DS.Ink.amber : DS.Ink.mint))
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(DS.mono(11, .semibold))
                                if let d = c.detail, !d.isEmpty {
                                    Text(d).font(DS.mono(10)).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    }
                    if checkFailed {
                        Text("Pre-send checks failed — reject to rework, do not approve")
                            .font(DS.mono(11, .semibold))
                            .foregroundStyle(DS.Ink.rose)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Canvas.app)
                .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
            }
            // ── Content under review ──
            if item.step.bodyInline != nil || item.step.bodyRef != nil || !deliverables.isEmpty || item.step.fallbackBody != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("For review")
                        .font(DS.display(12, .semibold))
                        .foregroundStyle(.secondary)
                    if let inline = item.step.bodyInline {
                        Text(inline)
                            .font(.system(size: 12))
                            .lineLimit(bodyExpanded ? nil : 8)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Canvas.app)
                            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                        Button(bodyExpanded ? "Collapse" : "Expand") {
                            withAnimation(DS.snappy) { bodyExpanded.toggle() }
                        }
                        .font(DS.mono(11, .semibold))
                        .tint(DS.Ink.mint)
                    } else if let fallback = item.step.fallbackBody {
                        // Contract-less fallback: last line of defense for the body when deliverable pointers are absent.
                        Text(fallback)
                            .font(.system(size: 12))
                            .lineLimit(bodyExpanded ? nil : 8)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Canvas.app)
                            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                        Button(bodyExpanded ? "Collapse" : "Expand") {
                            withAnimation(DS.snappy) { bodyExpanded.toggle() }
                        }
                        .font(DS.mono(11, .semibold))
                        .tint(DS.Ink.mint)
                    }
                    if let ref = item.step.bodyRef {
                        ContentRow(label: "Draft body", name: ref.name, bytes: nil) {
                            onPreview(PreviewTarget(id: ref.id, name: ref.name))
                        }
                    }
                    ForEach(Array(deliverables.enumerated()), id: \.offset) { _, d in
                        // Skip the same-name body artifact when body_ref already has its own row, to avoid duplicates.
                        if let id = d.id, !(item.step.bodyRef != nil && d.viewRole == "body") {
                            ContentRow(
                                label: d.viewRole == "body" ? "Body" : "Deliverables",
                                name: d.name,
                                bytes: d.bytes
                            ) {
                                onPreview(PreviewTarget(id: id, name: d.name))
                            }
                        }
                    }
                }
            }
            if let summary = item.step.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            HStack(spacing: 8) {
                TextField("Note (optional)", text: $note)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(DS.Canvas.app)
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                Button {
                    Task {
                        await vm.approve(item, note: note)
                        note = ""
                    }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Ink.mint)
                .disabled(vm.acting || checkFailed)
                .accessibilityLabel("Approve")
                Button {
                    onDeny(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(vm.acting)
                .accessibilityLabel("Reject")
                Button {
                    onRework(item)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(vm.acting)
                .accessibilityLabel("Reject & rework")
                Button {
                    Task {
                        await vm.resolve(item, note: note)
                        note = ""
                    }
                } label: {
                    Text("Handled")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(vm.acting)
            }
        }
        .padding(12)
        .background(DS.Canvas.inset)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
    }
}

// Tappable content pointer inside a gate card (opens the in-app preview).
struct ContentRow: View {
    let label: String
    let name: String
    let bytes: Int64?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Ink.mint)
                Text(label)
                    .font(DS.mono(10, .semibold))
                    .foregroundStyle(DS.Ink.mint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DS.Ink.mint.opacity(0.12))
                    .clipShape(Capsule())
                Text(name)
                    .font(DS.mono(12))
                    .lineLimit(1)
                Spacer()
                if let b = bytes {
                    Text(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))
                        .font(DS.mono(10))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(DS.Canvas.app)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Server timestamps are ISO8601 WITH fractional seconds ("…T02:38:47.227+08:00").
// The plain formatter silently returns nil on the ".227" — that nil cascade
// filtered every recently-settled workflow out of the list (the "empty Flow
// tab" bug), so all parsing goes through this tolerant helper.
enum MakroISO {
    static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
    static func date(from s: String) -> Date? {
        frac.date(from: s) ?? plain.date(from: s)
    }
    static let compact: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

// Cost analysis section (wf_6a74fc4a23e4): per-job API-equivalent cost × tier
// bucket distribution — KPI row + stacked bucket bars (Swift Charts). Collapsed
// by default; /api/lifecycle/cost-stats is fetched on first expand. Scatter /
// drill-down stays desktop-Web-only (not built for small screens; see
// FRONTEND-PARITY.md).
private struct CostAnalysisSection: View {
    @State private var expanded = false
    @State private var days: Int = 30
    @State private var stats: CostStats?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(DS.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Cost analysis").font(DS.display(14, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                    Text("Per-job API-equivalent cost × tier mix").font(DS.mono(10)).foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse cost analysis" : "Expand cost analysis")
            if expanded { content }
        }
        .padding(12)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
        .glassBorder(DS.R.md)
        .task(id: expanded) {
            guard expanded else { return }
            if stats == nil { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        if let s = stats {
            Picker("Period", selection: $days) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
                Text("All").tag(0)
            }
            .pickerStyle(.segmented)
            .onChange(of: days) { _ in Task { await load() } }
            kpiRow(s)
            bucketChart(s)
            footnote(s)
        } else if loadError != nil {
            Text(loadError!).font(DS.mono(11)).foregroundStyle(DS.Ink.rose)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Ink.rose.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading cost data…").font(DS.mono(11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }
    }

    private func load() async {
        loadError = nil
        do {
            stats = try await APIClient.shared.fetchCostStats(days: days)
        } catch {
            loadError = "Cost data failed to load: \(error.localizedDescription)"
        }
    }

    private func kpiRow(_ s: CostStats) -> some View {
        HStack(spacing: 8) {
            kpi("Total", Self.cny(s.overall.totalCny), "\(s.overall.ordersWithCost)/\(s.overall.workflows) jobs priced")
            kpi("Per job", Self.cny(s.overall.meanCny), "median \(Self.cny(s.overall.medianCny))")
            kpi("P90", Self.cny(s.overall.p90Cny), "max \(Self.cny(s.overall.maxCny))")
            kpi("Unpriced usage", "\(s.overall.zeroCostOrders)", "unattributed + gate-only jobs")
        }
    }

    private func kpi(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(DS.micro(9.5, .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(DS.mono(16, .semibold)).foregroundStyle(DS.Ink.mintDeep)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(DS.mono(8.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(DS.Canvas.inset)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.sm, style: .continuous))
    }

    /// Buckets × job count (stacked by model): bar value = job count, legend carries the model split.
    private func bucketChart(_ s: CostStats) -> some View {
        Chart {
            ForEach(s.buckets, id: \.label) { b in
                ForEach(b.byModel, id: \.model) { m in
                    BarMark(
                        x: .value("Tier", b.label),
                        y: .value("Jobs", m.count),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Model", m.label))
                    .cornerRadius(3)
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 200)
    }

    private func footnoteText(_ s: CostStats) -> String {
        var l = "Basis: per-job usageCost summed (BigModel list \(s.pricingRetrievedAt ?? "—") snapshot; cache/input/output rates; cancelled jobs included; \(days == 0 ? "All time" : "last \(days) days")."
        if let unpriced = s.unpricedOrders, !unpriced.isEmpty {
            l += " \(unpriced.count) jobs use models outside the price list (usage counted, not priced)."
        }
        return l
    }

    private func footnote(_ s: CostStats) -> some View {
        Text(footnoteText(s))
            .font(DS.mono(8.5)).foregroundStyle(.tertiary)
    }

    static func cny(_ v: Double) -> String {
        v >= 1000 ? String(format: "¥%,.0f", v) : String(format: "¥%.1f", v)
    }
}

private struct WorkflowListSection: View {
    // Workflows passed BY VALUE: a child holding the model by reference
    // ("let vm") never re-rendered when @Published changed — the list froze
    // on its first (pre-data, empty) render forever. Values force SwiftUI
    // to rebuild the rows whenever the data changes.
    let workflows: [LifecycleWorkflow]
    let vm: LifecycleViewModel

    @State private var filter: StatusFilter = .all
    @State private var newestFirst = true

    // Two-column cards (2026-10-01, same pattern as the Artifacts final 5bd3cdc)
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    @State private var appearedCards: Set<String> = []

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case queued = "Queued"
        case live = "Running"
        case waiting = "In review"
        case failed = "Failed"
        case completed = "Completed"
        case settled = "Cancelled"
        var id: String { label }
        var label: String { rawValue }
    }

    private static func matches(_ w: LifecycleWorkflow, _ f: StatusFilter) -> Bool {
        switch f {
        case .all: return true
        case .queued: return w.status == "queued"
        case .live: return ["running", "waiting_human"].contains(w.status)
        case .waiting: return w.status == "waiting_human"
        case .failed: return w.status == "failed"
        case .completed: return w.status == "completed"
        case .settled: return ["cancelled", "rejected"].contains(w.status)
        }
    }

    private var counts: [StatusFilter: Int] {
        var c: [StatusFilter: Int] = [:]
        for f in StatusFilter.allCases { c[f] = 0 }
        for w in workflows {
            for f in StatusFilter.allCases where Self.matches(w, f) {
                c[f, default: 0] += 1
            }
        }
        return c
    }

    private func ts(_ w: LifecycleWorkflow) -> Date {
        MakroISO.date(from: w.updated_at) ?? .distantPast
    }

    /// Under the iOS 26 SDK an inline Task in an onTapGesture closure makes the
    /// init ambiguous (sending @isolated(any) parameter) — hoisted into a method
    /// body for an explicit Void context.
    private func openWorkflow(_ id: String) {
        Task { await vm.select(id) }
    }

    /// The visible list: status filter + time sort, nothing else. Newest
    /// first naturally keeps active work on top (it is the most recently
    /// updated); the toggle covers "walk the history chronologically".
    private var displayList: [LifecycleWorkflow] {
        let sorted = workflows.sorted { newestFirst ? ts($0) > ts($1) : ts($0) < ts($1) }
        return sorted.filter { Self.matches($0, filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workflows")
                    .font(DS.display(15, .semibold))
                Spacer()
                Menu {
                    Button {
                        newestFirst = true
                    } label: {
                        Label("Newest first", systemImage: newestFirst ? "checkmark" : "")
                    }
                    Button {
                        newestFirst = false
                    } label: {
                        Label("Oldest first", systemImage: newestFirst ? "" : "checkmark")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Sort")
            }
            filterChips
            if workflows.isEmpty {
                Text(vm.errorMessage == nil
                     ? "No jobs yet — new email lands here"
                     : "List failed to load: \(vm.errorMessage ?? "")")
                    .font(.system(size: 13))
                    .foregroundStyle(vm.errorMessage == nil ? Color.secondary : DS.Ink.rose)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Canvas.inset)
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
            } else if displayList.isEmpty {
                Text("No jobs match \(filter.label)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Canvas.inset)
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(displayList) { w in
                    WorkflowCard(workflow: w)
                        .contentShape(RoundedRectangle(cornerRadius: DS.R.md))
                        .onTapGesture { openWorkflow(w.id) }
                        .opacity(appearedCards.contains(w.id) ? 1 : 0)
                        .offset(y: appearedCards.contains(w.id) ? 0 : 8)
                        .onAppear { withAnimation(DS.spring) { _ = appearedCards.insert(w.id) } }
                }
            }
            .padding(.top, 2)
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(StatusFilter.allCases) { f in
                    let n = counts[f] ?? 0
                    if f == .all || n > 0 {
                        chip(f, count: n)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func chip(_ f: StatusFilter, count: Int) -> some View {
        let selected = filter == f
        return Button {
            withAnimation(DS.snappy) { filter = f }
        } label: {
            HStack(spacing: 5) {
                Text(f.label)
                Text("\(count)")
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            }
            .font(DS.mono(11, .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? DS.Ink.mint : Color.secondary)
            .background(selected ? DS.Ink.mint.opacity(0.18) : DS.Canvas.inset)
            .overlay(
                Capsule().strokeBorder(selected ? DS.Ink.mint.opacity(0.5) : .clear, lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// Status encoding: color is only a redundancy, TEXT is the primary code —
// three terminal states (completed/cancelled/rejected) used to collapse into
// one indistinguishable gray dot.
enum FlowStatus {
    static func color(_ s: String) -> Color {
        switch s {
        case "queued": return DS.Ink.slate
        case "running": return DS.Ink.mint
        case "waiting_human": return DS.Ink.amber
        case "failed", "rejected": return DS.Ink.rose
        case "completed": return DS.Ink.done
        default: return DS.Ink.zinc // cancelled + anything unknown
        }
    }

    static func label(_ s: String) -> String {
        switch s {
        case "queued": return "Queued"
        case "running": return "Running"
        case "waiting_human": return "In review"
        case "failed": return "Failed"
        case "completed": return "Completed"
        case "cancelled": return "Cancelled"
        case "rejected": return "Rejected"
        default: return s
        }
    }

    /// Only live work breathes — motion separates "running" from the static
    /// mint of a finished case.
    static func animated(_ s: String) -> Bool { s == "running" }
}

// WorkflowCard (2026-10-01 two-column rework, same five layers as the
// ArtifactCard final 5bd3cdc): all six elements kept — status dot + breathing
// animation / status text / R round badge / two-line title body /
// kind·project·session·⏸waiting / relative time; one font-size step smaller
// overall, style parameters aligned with the artifact card.
private struct WorkflowCard: View {
    let workflow: LifecycleWorkflow

    private var statusColor: Color { FlowStatus.color(workflow.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ① Top row: status dot + status text + R badge | relative time
            HStack(alignment: .center, spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .breathing(FlowStatus.animated(workflow.status))
                Text(FlowStatus.label(workflow.status))
                    .font(DS.mono(9.5, .semibold))
                    .foregroundStyle(statusColor)
                if let r = workflow.meta?["round"]?.intValue, r >= 2 {
                    Text("R\(r)")
                        .font(DS.mono(9, .bold))
                        .foregroundStyle(DS.Ink.amber)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DS.Ink.amber.opacity(0.14))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                Text(Self.relativeTime(workflow.updated_at))
                    .font(DS.mono(9.5, .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            // ② Two-line title body (core win: long titles fully visible vs the old single-line truncation)
            Text(workflow.title)
                .font(DS.text(12.5, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            // ③④ Light divider + meta row (kind·project·session | ⏸waiting badge)
            HStack(spacing: 5) {
                Text(workflow.kind)
                if let p = workflow.project { Text("· \(p)") }
                if let s = workflow.session { Text("· @\(s)") }
                Spacer(minLength: 0)
                if let waiting = workflow.waiting_steps, waiting > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
                        Text("\(waiting)")
                    }
                        .font(DS.mono(9, .bold))
                        .foregroundStyle(DS.Ink.amber)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DS.Ink.amber.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            .font(DS.mono(9.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.top, 5)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 0.5)
            }
        }
        .padding(11)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
    }

    // Relative time (same as the artifact card): today HH:mm / yesterday / older MM-dd
    private static func relativeTime(_ iso: String) -> String {
        guard let date = MakroISO.date(from: iso) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "MM-dd"
        return f.string(from: date)
    }
}

struct WorkflowDetailSheet: View {
    @ObservedObject var vm: LifecycleViewModel
    let workflowID: String

    // Intervene-to-correct lives HERE (the sheet owns the running-step contextMenu) —
    // an earlier attempt parked this state in GateCard and read it from the
    // sheet: different structs, so the alert could never fire, and the
    // missing stepSession() helper left the tree unbuildable.
    @State private var interveneStep: LifecycleStep?
    @State private var interveneText = ""
    @State private var interveneError: String?
    @State private var reworkStepID: String?
    @State private var reworkFeedback = ""
    @State private var terminalSession: String?
    @State private var previewTarget: PreviewTarget?
    @State private var purgeArmed = false
    @State private var purgeError: String?
    @State private var closeTarget: LifecycleWorkflow?
    @State private var closeError: String?
    @State private var settleTarget: LifecycleWorkflow?
    @State private var isTogglingAutoApprove = false
    @State private var followUpFrom: LifecycleWorkflow?
    @State private var cancelStepID: String?
    @State private var cancelError: String?
    @State private var reworkSendID: String?
    @State private var reworkSendText = ""
    @State private var retryPlanID: String?
    @State private var retryPlanText = ""
    @State private var amendStep: LifecycleStep?
    @State private var amendError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let tree = vm.selectedTree {
                    // Board 05: case detail = hand-drawn card flow (standalone rounded
                    // white cards + section headers flat on the base color); the native
                    // List/Section is the old structure (same flaw as the Agents home;
                    // visual ruling: designed as divider-less cards).
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let err = vm.actionError {
                                Text(err).font(DS.mono(11)).foregroundStyle(DS.Ink.rose)
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DS.Ink.rose.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                            }
                            headerRow(tree.workflow)
                            RouteChainCard(w: tree.workflow)
                            CaseArtifactsSection(
                                vm: vm, workflowID: workflowID,
                                onPreview: { previewTarget = PreviewTarget($0) },
                                onPurge: { purgeArmed = true }
                            )
                            if let steps = tree.steps, !steps.isEmpty {
                                Text("Tier").font(DS.mono(11, .semibold)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(steps.enumerated()), id: \.element.id) { idx, st in
                                        // Compute the booleans before passing them into slots — an
                                        // inline ternary once blew the expression past type-check
                                        // timeout inside the ViewBuilder.
                                        let isFailed = st.status == "failed"
                                        let isSend = st.kind == "send"
                                        let isAgentStep = st.kind == "agent" || st.kind == "verify"
                                        StepTimelineRow(
                                            step: st,
                                            session: st.sessionName(in: tree.workflow),
                                            onRetry: { Task { await vm.retry(stepID: st.id) } },
                                            onTerminal: { terminalSession = $0 },
                                            showConnector: idx < steps.count - 1,
                                            onReworkSend: isFailed && isSend ? { reworkSendID = st.id } : nil,
                                            onRetryPlan: isFailed && isAgentStep ? { retryPlanID = st.id } : nil,
                                            onAmend: isFailed ? { amendStep = st } : nil
                                        )
                                        .contextMenu { stepMenu(st, tree.workflow) }
                                    }
                                    HStack(spacing: 6) {
                                        Image(systemName: "bubble.left").font(.system(size: 9))
                                        Text("Long-press a running step to intervene · notes are traced and keep the heartbeat alive")
                                    }
                                    .font(DS.mono(9.5)).foregroundStyle(DS.Ink.mintDeep)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(red: 1.0, green: 0.973, blue: 0.941))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .padding(12)
                                .background(DS.Canvas.card)
                                .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                } else if let err = vm.selectedError {
                    VStack(spacing: 10) {
                        Text("Failed to load").font(.system(size: 15, weight: .semibold))
                        Text(err).font(DS.mono(12)).foregroundStyle(DS.Ink.rose)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await vm.select(workflowID) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DetailSkeleton()
                }
            }
            // Intervene-to-correct (board 11): voice as a first-class input + editable transcript + errors shown in place.
            .sheet(item: $interveneStep) { st in
                InterveneSheet(vm: vm, step: st)
            }
            // Follow-up job (relates_to attaches it to the causal chain).
            .sheet(item: $followUpFrom) { w in
                TaskComposerView(relatesTo: w.id) { newID in
                    Task { await vm.select(newID) }
                }
            }
            // Amend-inputs sheet (amend-suggestions prefills candidate values).
            .sheet(item: $amendStep) { st in
                AmendSheet(vm: vm, step: st)
            }
            // Settle confirmation.
            .confirmationDialog(
                "Settle \(settleTarget?.title ?? "")?",
                isPresented: Binding(get: { settleTarget != nil }, set: { if !$0 { settleTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Settle (as completed)") {
                    if let w = settleTarget { Task { await vm.settle(w.id) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Explicit settle for nodes mode; rejected with a reason if steps are in flight")
            }
            // Cancel-this-step confirmation.
            .confirmationDialog(
                "Cancel this step?",
                isPresented: Binding(get: { cancelStepID != nil }, set: { if !$0 { cancelStepID = nil } }),
                titleVisibility: .visible
            ) {
                Button("Cancel this step (job unaffected)", role: .destructive) {
                    if let id = cancelStepID { Task { await vm.cancelStep(id) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only steps that have not started are eligible; the output is marked + an audit event is written, nothing is deleted")
            }
            // Amend & resend note.
            .alert("Amend & resend", isPresented: Binding(
                get: { reworkSendID != nil }, set: { if !$0 { reworkSendID = nil } })) {
                TextField("What to amend…", text: $reworkSendText)
                Button("Resend") {
                    if let id = reworkSendID, !reworkSendText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await vm.reworkSend(id, feedback: reworkSendText) }
                    }
                    reworkSendText = ""
                }
                Button("Cancel", role: .cancel) { reworkSendText = "" }
            } message: {
                Text("The agent amends per your note, then re-enters the send gate")
            }
            // Retry with new instructions.
            .alert("Retry with new instructions", isPresented: Binding(
                get: { retryPlanID != nil }, set: { if !$0 { retryPlanID = nil } })) {
                TextField("How should it run this time…", text: $retryPlanText)
                Button("Retry") {
                    if let id = retryPlanID, !retryPlanText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await vm.retryWithPlan(id, plan: retryPlanText) }
                    }
                    retryPlanText = ""
                }
                Button("Cancel", role: .cancel) { retryPlanText = "" }
            } message: {
                Text("The plan overrides the original instructions; session unchanged")
            }
            .alert("Reject & rework", isPresented: Binding(
                get: { reworkStepID != nil },
                set: { if !$0 { reworkStepID = nil } })) {
                TextField("What should change…", text: $reworkFeedback)
                Button("Confirm rework") {
                    if let id = reworkStepID, !reworkFeedback.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await vm.rework(stepID: id, feedback: reworkFeedback) }
                    }
                    reworkFeedback = ""
                }
                Button("Cancel", role: .cancel) { reworkFeedback = "" }
            } message: {
                Text("The feedback is injected into the previous step, round +1, run continues")
            }
            .sheet(item: $previewTarget) { target in
                CaseArtifactPreview(target: target)
            }
            .fullScreenCover(isPresented: Binding(
                get: { terminalSession != nil },
                set: { if !$0 { terminalSession = nil } }
            )) {
                NavigationStack {
                    TerminalDetailView(
                        sessionName: terminalSession ?? "",
                        onClose: { terminalSession = nil }
                    )
                }
            }
            .confirmationDialog("Purge all attachment bytes for this case?", isPresented: $purgeArmed, titleVisibility: .visible) {
                Button("Purge bytes (facts stay on record)", role: .destructive) {
                    Task {
                        do {
                            try await vm.purgeCaseArtifacts(workflowID)
                        } catch {
                            purgeError = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("File contents on disk/OSS are deleted; facts and metadata stay in the ledger")
            }
            .alert("Purge failed", isPresented: Binding(
                get: { purgeError != nil },
                set: { if !$0 { purgeError = nil }
                })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(purgeError ?? "")
            }
            .confirmationDialog(
                "Force close \(closeTarget?.title ?? "")?",
                isPresented: Binding(
                    get: { closeTarget != nil },
                    set: { if !$0 { closeTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Force close (all in-flight steps cancelled)", role: .destructive) {
                    if let w = closeTarget {
                        Task {
                            do {
                                try await vm.forceClose(w.id, note: "iphone force-closed")
                            } catch {
                                closeError = error.localizedDescription
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The run ends immediately, waiting for no gate; finished facts stay in the ledger")
            }
            .alert("Close failed", isPresented: Binding(
                get: { closeError != nil },
                set: { if !$0 { closeError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(closeError ?? "")
            }
            .navigationTitle(vm.selectedTree?.workflow.title ?? "Workflow")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func stepMenu(_ st: LifecycleStep, _ w: LifecycleWorkflow) -> some View {
        // First-class intervene: only in-flight agent/verify steps (server
        // enforces the same rule and rejects anything else).
        if st.status == "running" && (st.kind == "agent" || st.kind == "verify") {
            Button {
                interveneStep = st
            } label: {
                if let sess = st.sessionName(in: w) {
                    Label("Intervene @\(sess)", systemImage: "bubble.left")
                } else {
                    Label("Intervene", systemImage: "bubble.left")
                }
            }
            if let sess = st.sessionName(in: w) {
                Button {
                    terminalSession = sess
                } label: {
                    Label("Open in terminal @\(sess)", systemImage: "terminal")
                }
            }
        }
        if st.isGate && st.isWaiting {
            Button {
                reworkStepID = st.id
            } label: {
                Label("Reject & rework", systemImage: "arrow.uturn.backward")
            }
        }
        // Scheduled send: schedules delivery when approving the send gate (default tomorrow 09:00, timezone courtesy).
        if st.isGate && st.isWaiting,
           (vm.selectedTree?.steps ?? []).contains(where: { $0.kind == "send" && $0.status == "pending" }) {
            Button {
                Task { await vm.scheduleApprove(stepID: st.id, at: Self.tomorrow9am()) }
            } label: {
                Label("Scheduled (tomorrow 9:00)", systemImage: "clock.badge.checkmark")
            }
        }
        // Cancel one step: does not affect the whole job (only not-yet-started steps are legal; server validates).
        if st.status == "pending" || st.status == "waiting_human" {
            Button(role: .destructive) {
                cancelStepID = st.id
            } label: {
                Label("Cancel step", systemImage: "minus.circle")
            }
        }
        // Correction channel after the send guard refuses.
        if st.status == "failed" && st.kind == "send" {
            Button {
                reworkSendID = st.id
            } label: {
                Label("Amend & resend", systemImage: "arrowshape.turn.up.right")
            }
        }
        // Retry with new instructions: corrective retry for failed agent/verify steps.
        if st.status == "failed" && (st.kind == "agent" || st.kind == "verify") {
            Button {
                retryPlanID = st.id
            } label: {
                Label("Retry with new instructions", systemImage: "square.and.pencil")
            }
        }
        // Amend inputs: failed steps missing input; the engine prefills candidate values.
        if st.status == "failed" {
            Button {
                amendStep = st
            } label: {
                Label("Amend inputs (edit & rerun)", systemImage: "tray.and.arrow.down")
            }
        }
    }

    static func tomorrow9am() -> Date {
        let cal = Calendar.current
        return cal.nextDate(after: Date(),
                            matching: DateComponents(hour: 9, minute: 0),
                            matchingPolicy: .nextTime) ?? Date().addingTimeInterval(24 * 3600)
    }

    static func fmtTokensShort(_ v: Double) -> String {
        switch v {
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return String(format: "%.0f", v)
        }
    }

    private func headerRow(_ w: LifecycleWorkflow) -> some View {
        // Session chips are ALWAYS tappable — this is the Flow→Agents seam.
        // A plain "@x" text here was the exact discoverability failure the
        // operator called out: navigation must be visible, not hidden in a
        // long-press menu.
        let assigned = w.meta?["assigned_session"]?.stringValue
        var seen = Set<String>()
        let sessions = [w.session, assigned].compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(w.title).font(.system(size: 16, weight: .semibold))
                if let r = w.meta?["round"]?.intValue, r >= 2 {
                    Text("R\(r)")
                        .font(DS.mono(9, .bold))
                        .foregroundStyle(DS.Ink.amber)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.Ink.amber.opacity(0.14))
                        .clipShape(Capsule())
                }
                if w.auto_approve == true {
                    Text("⚡ Auto-approving")
                        .font(DS.mono(9, .semibold))
                        .foregroundStyle(DS.Ink.mintDeep)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.Ink.mint.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            HStack(spacing: 6) {
                Text(FlowStatus.label(w.status))
                    .foregroundStyle(FlowStatus.color(w.status))
                if let p = w.project { Text("· \(p)") }
                // Per-workflow prompt count (wf_2542c2c7eb13): Round = prompt count
                // semantics clarified — LLM turns in its session during this job's
                // execution (not the workflow count).
                if let ps = vm.selectedTree?.promptStats, ps.count > 0 {
                    Text("· Prompts \(ps.count)")
                        .foregroundStyle(DS.Ink.mintDeep)
                    Text("(in \(Self.fmtTokensShort(ps.inputTokens)) / out \(Self.fmtTokensShort(ps.outputTokens)))")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(DS.mono(12))
            .foregroundStyle(.tertiary)
            // API-equivalent price (wf_535149a174fe): models actually used by this
            // job × the official BigModel price list — cache/input/output priced
            // separately and summed, i.e. "what it would cost via the API".
            // Models not in the price list (jev/claude family/delisted) are
            // named but not priced.
            if let uc = vm.selectedTree?.usageCost, !uc.byModel.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "yensign.circle")
                        .foregroundStyle(DS.Ink.amber)
                    ForEach(uc.byModel, id: \.model) { m in
                        Text(m.priced
                             ? "\(m.label) \(m.free ? "Free" : String(format: "≈¥%.2f", m.costCny.total))"
                             : "\(m.model)·unpriced")
                            .foregroundStyle(m.priced ? DS.Ink.mintDeep : .secondary)
                            .help(m.priced
                                  ? String(format: "cache ¥%.4f + input ¥%.4f + output ¥%.4f (tier: %@)", m.costCny.cache, m.costCny.input, m.costCny.output, m.tiersHit?.joined(separator: " / ") ?? "")
                                  : "not in the BigModel price list — usage counted, not priced")
                    }
                    if uc.totalCny.total > 0 {
                        Text(String(format: "· total ≈¥%.2f", uc.totalCny.total))
                            .foregroundStyle(DS.Ink.amber)
                            .help(String(format: "cache ¥%.4f + input ¥%.4f + output ¥%.4f (list %@)", uc.totalCny.cache, uc.totalCny.input, uc.totalCny.output, uc.pricingRetrievedAt ?? ""))
                    }
                }
                .font(DS.mono(11))
                .foregroundStyle(.secondary)
            }
            // Email origin: which message started this case (from/subject
            // copied into meta by the engine at intake).
            if let from = w.meta?["from"]?.stringValue, !from.isEmpty {
                Text("Inbound · \(w.meta?["subject"]?.stringValue ?? "(no subject)") · \(from)")
                    .font(DS.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !sessions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(sessions, id: \.self) { s in
                        let isAssigned = s == assigned
                        Button {
                            terminalSession = s
                        } label: {
                            Label(isAssigned ? "working @\(s)" : "@\(s)", systemImage: "terminal")
                                .font(DS.mono(11, .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background((isAssigned ? DS.Ink.mint : Color.secondary).opacity(0.12))
                                .foregroundStyle(isAssigned ? DS.Ink.mint : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open in terminal @\(s)")
                    }
                    // Per-workflow auto-approve toggle (2026-10-07): turning it on immediately triggers a server sweep.
                    if w.status == "running" || w.status == "queued" || w.status == "waiting_human" {
                        let autoOn = w.auto_approve == true
                        Button {
                            Task { @MainActor in
                                isTogglingAutoApprove = true
                                defer { isTogglingAutoApprove = false }
                                do {
                                    try await vm.setAutoApprove(w.id, on: !autoOn)
                                    await vm.reloadSelected()
                                } catch { vm.actionError = "Auto-approve toggle failed: \(error.localizedDescription)" }
                            }
                        } label: {
                            Label(autoOn ? "review" : "auto", systemImage: autoOn ? "person.crop.circle" : "bolt.badge.automatic")
                                .font(DS.mono(11, .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background((autoOn ? DS.Ink.zinc : DS.Ink.mint).opacity(0.12))
                                .foregroundStyle(autoOn ? Color.secondary : DS.Ink.mintDeep)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isTogglingAutoApprove)
                        .accessibilityLabel(autoOn ? "Restore human approval" : "Auto-approve this job (non-send gates)")
                    }
                    // Terminal escape hatch: a running pipeline can be force-closed at any time (all in-flight steps cancelled).
                    if w.status == "running" {
                        Button {
                            settleTarget = w
                        } label: {
                            Label("Settle", systemImage: "checkmark.seal")
                                .font(DS.mono(11, .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(DS.Ink.done.opacity(0.12))
                                .foregroundStyle(DS.Ink.done)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settle this run")
                        Button {
                            closeTarget = w
                        } label: {
                            Label("Force close", systemImage: "xmark.octagon")
                                .font(DS.mono(11, .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(DS.Ink.rose.opacity(0.12))
                                .foregroundStyle(DS.Ink.rose)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Force-close this run")
                    }
                    if w.status == "failed" {
                        Button {
                            Task { await vm.closeFailed(w.id, note: "iphone close-out") }
                        } label: {
                            Label("Close out", systemImage: "archivebox")
                                .font(DS.mono(11, .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(DS.Ink.zinc.opacity(0.14))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close out this failed casefile")
                    }
                    if w.status != "running" {
                        Button {
                            followUpFrom = w
                        } label: {
                            Label("Follow-up", systemImage: "arrow.triangle.branch")
                                .font(DS.mono(11, .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(DS.Ink.mint.opacity(0.12))
                                .foregroundStyle(DS.Ink.mint)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start a follow-up")
                    }
                }
            }
        }
    }
}

// Case evidence: every artifact version grouped by role; tap opens the
// in-app authenticated preview (the artifact endpoint sits behind Bearer
// auth + self-signed TLS, so Safari/link-out can never load it). Purge
// removes bytes, facts stay.
private struct CaseArtifactsSection: View {
    @ObservedObject var vm: LifecycleViewModel
    let workflowID: String
    let onPreview: (CaseArtifact) -> Void
    let onPurge: () -> Void

    private var artifacts: [CaseArtifact] { vm.selectedArtifacts }

    private var grouped: [(role: String, items: [CaseArtifact])] {
        Dictionary(grouping: artifacts, by: \.role)
            .map { (role: $0.key, items: $0.value.sorted { ($0.name, $0.seq) < ($1.name, $1.seq) }) }
            .sorted { $0.role < $1.role }
    }

    var body: some View {
        // Board 05: section headers flat on the base color + standalone white cards (the List form was retired with the container rewrite).
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments & outputs · \(artifacts.count)")
                .font(DS.mono(11, .semibold)).foregroundStyle(.secondary)
            if artifacts.isEmpty {
                Text("No attachments or outputs")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Canvas.inset)
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(grouped, id: \.role) { group in
                        ForEach(group.items) { a in
                            ArtifactRow(artifact: a)
                                .contentShape(Rectangle())
                                .onTapGesture { onPreview(a) }
                        }
                        .buttonStyle(.plain)
                    }
                    Button(role: .destructive, action: onPurge) {
                        Text("Purge attachment bytes (facts stay)").font(.system(size: 13))
                    }
                }
                .padding(12)
                .background(DS.Canvas.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
            }
        }
    }
}

// In-app authenticated preview. Downloads bytes through the shared pinned
// URLSession, then renders by mime: HTML string → WKWebView, video → local
// temp file + AVPlayer (remote URLs fail cert validation), images and text
// render directly. Gate deliverable pointers carry no mime → sniffed.
struct CaseArtifactPreview: View {
    let target: PreviewTarget
    @State private var state: LoadState = .loading
    @Environment(\.dismiss) private var dismiss

    enum LoadState: Equatable {
        case loading
        case html(String)
        case video(URL)
        case image(UIImage)
        case text(String)
        case pdf(URL)
        case quicklook(URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading…")
                case .html(let html):
                    HTMLPreviewView(html: html)
                case .video(let url):
                    VideoPreviewView(url: url)
                case .pdf(let url):
                    PDFPreviewView(url: url)
                case .quicklook(let url):
                    QuickLookPreview(url: url)
                case .image(let img):
                    ScrollView {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    }
                case .text(let txt):
                    ScrollView {
                        Text(txt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                case .failed(let msg):
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(DS.Ink.amber)
                        Text(msg)
                            .font(DS.text(13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                }
            }
            .background(DS.Canvas.app.ignoresSafeArea())
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Completed") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        // Large-attachment gate: pulling a 50MB+ PPTX on a phone is slow and memory-hungry — steer to desktop.
        if let b = target.bytes, b > 50 * 1024 * 1024 {
            let size = ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
            await MainActor.run { state = .failed("File too large (\(size)) — best viewed on desktop") }
            return
        }
        do {
            let data = try await APIClient.shared.fetchCaseArtifactContent(id: target.id)
            // Resolution order: bytes first (the ledger's stored mime can be
            // a sweep-time fallback like octet-stream on a real HTML file),
            // then the stored hint, then the file extension.
            let mime = Self.resolve(data, stored: target.mime, name: target.name)
            if mime.contains("text/html") {
                let html = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run { state = .html(html) }
            } else if mime == "application/pdf" || Self.ext(target.name) == "pdf" {
                let tmp = try Self.localFile(data: data, name: target.name, fallbackExt: "pdf")
                await MainActor.run { state = .pdf(tmp) }
            } else if Self.isOffice(mime: mime, name: target.name) {
                let tmp = try Self.localFile(data: data, name: target.name, fallbackExt: Self.officeExt(mime: mime))
                await MainActor.run { state = .quicklook(tmp) }
            } else if mime.hasPrefix("video/") {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(target.name)
                try data.write(to: tmp)
                await MainActor.run { state = .video(tmp) }
            } else if mime.hasPrefix("image/"),
                      let img = UIImage(data: data) {
                await MainActor.run { state = .image(img) }
            } else if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || mime.contains("csv"),
                      let txt = String(data: data, encoding: .utf8) {
                await MainActor.run { state = .text(txt) }
            } else {
                let kb = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                await MainActor.run { state = .failed("No preview for this type (\(mime)) · \(kb)") }
            }
        } catch {
            await MainActor.run { state = .failed(error.localizedDescription) }
        }
    }

    /// mime resolution: sniffed bytes win over stored hint; extension map is
    /// the last resort. "octet-stream" from the ledger is a non-answer, not
    /// a fact — it must never block a sniffable file.
    // MARK: Document preview helpers (PDF / QuickLook)

    static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Office formats QuickLook handles (read-only rendering, system-level fidelity).
    static let officeExtensions: Set<String> = [
        "docx", "doc", "xlsx", "xls", "pptx", "ppt", "rtf", "odt", "ods", "odp", "pages", "numbers", "key",
    ]

    static func isOffice(mime: String, name: String) -> Bool {
        if officeExtensions.contains(ext(name)) { return true }
        return mime.contains("officedocument") || mime.contains("msword")
            || mime.contains("ms-powerpoint") || mime.contains("ms-excel")
            || mime.contains("opendocument")
    }

    /// Derive one from the mime type when the extension is missing (QuickLook/PDFKit both identify files by extension).
    static func officeExt(mime: String) -> String {
        if mime.contains("wordprocessing") || mime.contains("msword") { return "docx" }
        if mime.contains("spreadsheet") || mime.contains("ms-excel") { return "xlsx" }
        if mime.contains("presentation") || mime.contains("ms-powerpoint") { return "pptx" }
        return "bin"
    }

    /// Write to a temp file (extension preserved; renderers identify the format by it).
    static func localFile(data: Data, name: String, fallbackExt: String) throws -> URL {
        var n = name
        if ext(n).isEmpty { n += "." + fallbackExt }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(n)
        try data.write(to: tmp)
        return tmp
    }

    static func resolve(_ data: Data, stored: String?, name: String) -> String {        let sniffed = sniff(data)
        if sniffed != "application/octet-stream" { return sniffed }
        if let s = stored, !s.isEmpty, s != "application/octet-stream" { return s }
        return Self.mimeFromName(name) ?? "application/octet-stream"
    }

    static func mimeFromName(_ name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "json": return "application/json"
        case "txt", "md", "log", "csv", "xml": return "text/plain"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        default: return nil
        }
    }

    /// Content sniffing for mime-less pointers (gate deliverables): magic
    /// bytes first, then structural text heuristics, then plain-text fallback.
    static func sniff(_ data: Data) -> String {
        if data.prefix(5) == Data("%PDF-".utf8) { return "application/pdf" }
        if data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.prefix(4) == Data("GIF8".utf8) { return "image/gif" }
        if data.count > 8, data.subdata(in: 4..<8) == Data("ftyp".utf8) { return "video/mp4" }
        if let head = String(data: data.prefix(512), encoding: .utf8) {
            let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("<") { return "text/html" }
            if t.hasPrefix("{") || t.hasPrefix("[") { return "application/json" }
            if !head.contains("\0") { return "text/plain" }
        }
        return "application/octet-stream"
    }
}

private struct ArtifactRow: View {
    let artifact: CaseArtifact

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(artifact.isPurged ? Color.secondary : DS.Ink.mint)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(artifact.name).font(DS.mono(12)).lineLimit(1)
                    if artifact.seq > 1 {
                        Text("v\(artifact.seq)").font(DS.mono(9)).foregroundStyle(DS.Ink.mint)
                    }
                }
                Text("\(artifact.roleLabel) · \(artifact.mime ?? "-") · \(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))")
                    .font(DS.mono(10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if artifact.isPurged {
                Text("Purged").font(DS.mono(9)).foregroundStyle(.secondary)
            } else if artifact.hasBytes {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Ink.mint)
            } else {
                Text("Over limit, not stored").font(DS.mono(9)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct StepTimelineRow: View {
    let step: LifecycleStep
    var session: String?
    let onRetry: () -> Void
    var onTerminal: ((String) -> Void)? = nil
    var showConnector = true
    // A guard refusal is not a dead end (2026-09-20 wf_fb099d0e9f11 incident):
    // repair actions were pinned from the long-press menu onto the card face —
    // an entry hidden in a long-press effectively does not exist (our own UX
    // discipline).
    var onReworkSend: (() -> Void)? = nil
    var onRetryPlan: (() -> Void)? = nil
    var onAmend: (() -> Void)? = nil

    var dotColor: Color {
        switch step.status {
        case "completed": return DS.Ink.done
        case "running": return DS.Ink.amber
        case "waiting_human": return DS.Ink.amber
        case "failed": return DS.Ink.rose
        default: return DS.Ink.zinc
        }
    }

    var statusLabel: String {
        switch step.status {
        case "waiting_human": return "In review"
        case "running": return "Running"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "pending": return "Waiting"
        default: return step.status
        }
    }

    private func repairButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DS.mono(10, .semibold))
                .foregroundStyle(DS.Ink.mintDeep)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(DS.Ink.mint.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .top) {
                if showConnector {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 1.5)
                        .padding(.leading, 3.25)
                }
                Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(step.seq). \(step.displayTitle)")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    if let t = step.timingLabel {
                        HStack(spacing: 3) {
                            Image(systemName: "clock").font(.system(size: 9))
                            Text(t)
                        }
                            .font(DS.mono(10))
                            .foregroundStyle(.secondary)
                    }
                    Text(statusLabel)
                        .font(DS.mono(11))
                        .foregroundStyle(.tertiary)
                }
                if let summary = step.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                // Why it failed: the engine stashes the reason on output.error;
                // a bare "Retry" without the reason just retries blind.
                if let err = step.outputError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Ink.rose)
                        .lineLimit(4)
                }
                // A guard refusal is not a dead end (2026-09-20 wf_fb099d0e9f11
                // incident): repair actions are tappable in place — send → amend
                // & resend; agent/verify → retry with new instructions; other
                // failures → amend inputs. Retry as-is is always last (for send
                // it would most likely hit the same guard again).
                if step.status == "failed" {
                    HStack(spacing: 8) {
                        if step.kind == "send", let onReworkSend {
                            repairButton("Amend & resend", icon: "arrowshape.turn.up.right", action: onReworkSend)
                        }
                        if step.kind == "agent" || step.kind == "verify", let onRetryPlan {
                            repairButton("Retry with new instructions", icon: "square.and.pencil", action: onRetryPlan)
                        }
                        if step.kind != "send", let onAmend {
                            repairButton("Amend inputs", icon: "tray.and.arrow.down", action: onAmend)
                        }
                        Button(action: onRetry) {
                            Label("Retry as-is", systemImage: "arrow.clockwise")
                                .font(DS.mono(10, .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
                // Send receipt: to whom, when, and which attachments went along — the visible end state of a completed send.
                if let receipt = step.sendReceipt {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Ink.mint)
                            Text("Sent to \(receipt.to)")
                                .font(DS.mono(11, .semibold))
                                .foregroundStyle(DS.Ink.mint)
                        }
                        if let at = receipt.sentAt.flatMap(MakroISO.date(from:)) {
                            Text(MakroISO.compact.string(from: at))
                                .font(DS.mono(10))
                                .foregroundStyle(.tertiary)
                        }
                        if !receipt.attachments.isEmpty {
                            Text("Attachments: \(receipt.attachments.joined(separator: ", "))")
                                .font(DS.mono(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                if step.status == "failed" || (session != nil && onTerminal != nil) {
                    HStack(spacing: 8) {
                        if let sess = session, let cb = onTerminal {
                            Button { cb(sess) } label: {
                                Label("Terminal", systemImage: "terminal")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(DS.Ink.mint)
                            .controlSize(.mini)
                            .accessibilityLabel("Open in terminal @\(sess)")
                        }
                        if step.status == "failed" {
                            Button("Retry", action: onRetry)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Skeleton loading (board 13): breathing gray bars, never blank
struct SkeletonBar: View {
    var width: CGFloat? = nil
    @State private var phase = false
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(phase ? 0.10 : 0.18))
            .frame(width: width, height: 10)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.secondary.opacity(0.14)).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBar(width: 180)
                SkeletonBar(width: 120)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct DetailSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<5, id: \.self) { _ in SkeletonRow() }
            }
            .padding(20)
        }
    }
}

// MARK: - Route chain card (board F · applied 2026-09-20, some elements in phase 2)
// Opening a case shows the path it took through the mesh: four hops
// (inbound → company → domain → session). Data comes from flat meta keys the
// engine writes at intake (route_chain/company/domain/session/reasons) — the
// decision is made once in the engine; this is a pure projection. Older jobs
// without these keys render nothing (no guessing).
// Board F landed: per-hop decision reason lines (route_reasons split on \n,
// written by engine ≥2026-09-20), the fallback amber state (when the resolved
// target session w.session ≠ the judged target route_session, the final hop
// gets an amber background + ⚠ "fallback", plus a "⚠ fell back" badge next to
// the title), and the raw route_decision expandable at the bottom.
// Not landed (phase 2): per-hop timestamps (they exist in events, not yet
// scheduled for the route card); the desktop web right rail is board H.
private struct RouteChainCard: View {
    let w: LifecycleWorkflow

    private var chain: [String]? {
        guard let c = w.meta?["route_chain"]?.stringValue, !c.isEmpty else { return nil }
        return c.split(separator: ">").map(String.init)
    }

    /// Per-hop decision reasons (board F): route_reasons split on \n into four
    /// lines, same order as the chain. If the key is missing (old jobs) or the
    /// count does not match, no reason lines render (no guessing).
    private var reasons: [String]? {
        guard let r = w.meta?["route_reasons"]?.stringValue, !r.isEmpty else { return nil }
        let lines = r.components(separatedBy: "\n")
        guard lines.count == 4 else { return nil }
        return lines
    }

    /// Fallback state: the resolved target session (w.session, where the engine's
    /// resolveSession actually redirected) ≠ the intake-judged target
    /// (route_session). No fallback claim when the judged key is missing or the
    /// actual target is unknown.
    private var fallback: Bool {
        guard let judged = w.meta?["route_session"]?.stringValue, !judged.isEmpty,
              let actual = w.session, !actual.isEmpty else { return false }
        return actual != judged
    }

    var body: some View {
        if let chain, chain.count == 4 {
            // Empty string is not nil — `?.stringValue ?? "—"` would render a blank line for empty fields (P2⑦).
            let or = { (v: String?) -> String in (v?.isEmpty ?? true) ? "—" : v! }
            let company = or(w.meta?["route_company"]?.stringValue)
            let domain = or(w.meta?["route_domain"]?.stringValue)
            let judgedSession = w.meta?["route_session"]?.stringValue ?? ""
            let from = or(w.meta?["from"]?.stringValue)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Route · this job’s path through the mesh")
                        .font(DS.mono(11, .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if fallback {
                        // Board F fallback badge: called out next to the title when the engine redirected the final hop.
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                            Text("fell back")
                        }
                            .font(DS.mono(9, .semibold)).foregroundStyle(DS.Ink.amber)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    routeHop(icon: "envelope", title: "Inbound", value: from, hot: true, reason: reasons?[0])
                    hopConnector
                    routeHop(icon: "circle.fill", title: "Company", value: company, hot: true, reason: reasons?[1])
                    hopConnector
                    routeHop(icon: "diamond.fill", title: "Domain", value: domain, hot: true, reason: reasons?[2])
                    hopConnector
                    // Final hop: mint background to close — see at a glance which
                    // session this job landed in; on fallback it turns amber + ⚠
                    // "fallback", and the actual session overrides the judged one
                    // (board F).
                    HStack(spacing: 9) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(fallback ? DS.Ink.amber : DS.Ink.mint)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fallback ? "Session · judged \(or(w.meta?["route_session"]?.stringValue))" : "Session")
                                .font(DS.mono(9)).foregroundStyle(.tertiary)
                            Text(fallback ? (w.session ?? judgedSession) : judgedSession)
                                .font(DS.mono(13, .semibold))
                                .foregroundStyle(fallback ? DS.Ink.amber : DS.Ink.mintDeep)
                        }
                        Spacer()
                        if fallback {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                                Text("fallback")
                            }.font(DS.mono(9, .semibold)).foregroundStyle(DS.Ink.amber)
                        } else {
                            Text(chain[3] == "bound" ? "bound direct" : "default route")
                                .font(DS.mono(9)).foregroundStyle(chain[3] == "bound" ? DS.Ink.mintDeep : Color.secondary)
                        }
                    }
                    .padding(9)
                    .background(fallback ? DS.Ink.amber.opacity(0.12) : DS.Ink.mint.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.btn, style: .continuous))
                }
                if let reasons {
                    // Raw route_decision (board F "expandable"): chain + four reason
                    // lines, a pure projection of meta already on the ledger — no
                    // second request.
                    DisclosureGroup("route_decision · raw") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chain.joined(separator: " → "))
                                .font(DS.mono(9)).foregroundStyle(.secondary)
                            ForEach(Array(reasons.enumerated()), id: \.offset) { _, line in
                                if !line.isEmpty {
                                    Text(line).font(DS.mono(9)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(DS.mono(9))
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(DS.Canvas.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
        }
    }

    private var hopConnector: some View {
        Rectangle().fill(DS.Ink.mint.opacity(0.55))
            .frame(width: 2, height: 10)
            .padding(.leading, 18)
    }

    private func routeHop(icon: String, title: String, value: String, hot: Bool, reason: String? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(DS.Canvas.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.mono(9)).foregroundStyle(.tertiary)
                Text(value).font(DS.mono(12, .semibold)).foregroundStyle(.primary).lineLimit(1)
                if let reason, !reason.isEmpty {
                    Text(reason).font(DS.mono(9)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(9)
        .background(DS.Canvas.inset.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.R.btn, style: .continuous))
    }
}
