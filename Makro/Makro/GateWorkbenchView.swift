import SwiftUI

// 闸门工作台（Penpot 板 03 · makro-iphone）——全屏决策面。
// 收件箱卡片是"瞄一眼"，这里是"看全再签"：前置检查、将发送的正文全文、
// 随信附件、备注，全部铺开；决策区吸底常驻三键（驳回/对齐/批准），
// 不用滚去找按钮。板规格：驳回 #E8C7C2 描边 / 对齐 #EAD9B0 描边 /
// 批准 #D97C26 填充，圆角 10，高 40。

struct GateWorkbenchView: View {
    let item: GateQueueItem
    @ObservedObject var vm: LifecycleViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var note = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var bodyExpanded = false
    @State private var workTree: LifecycleWorkflowTree?
    @State private var previewTarget: PreviewTarget?
    @State private var showRework = false
    @State private var alignText = ""
    @State private var showAlign = false

    private var checks: [GateCheck] { item.step.checkItems }
    private var checkFailed: Bool { item.step.hasFailedCheck }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerLine
                    checksCard
                    bodyCard
                    if !item.step.deliverableItems.isEmpty { attachmentsCard }
                    noteCard
                    if let errorText { workbenchError(errorText) }
                    Text("发起 ≠ 自动发送：批准后按引擎节奏走；全部动作写账本（by: iphone）")
                        .font(DS.mono(9.5)).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            decisionBar
        }
        .sheet(item: $previewTarget) { t in
            CaseArtifactPreview(target: t)
        }
        .sheet(isPresented: $showRework) {
            ReworkSheet(item: item, vm: vm)
        }
        .alert("对齐修正", isPresented: $showAlign) {
            TextField("人定稿的修正意见…", text: $alignText)
            Button("入档并继续") {
                let text = alignText.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && !busy {
                    busy = true
                    Task {
                        do {
                            try await APIClient.shared.alignStep(stepID: item.step.id, amendment: text)
                            dismiss()
                            await vm.refresh()
                        } catch { errorText = error.localizedDescription }
                        busy = false
                    }
                }
                alignText = ""
            }
            Button("取消", role: .cancel) { alignText = "" }
        } message: {
            Text("修正成为 amendment 工件入档，下游 agent 锚定人定稿版本，流程继续")
        }
        .background(DS.Canvas.app.ignoresSafeArea())
        .navigationTitle(item.step.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("‹ 返回") { dismiss() }.foregroundStyle(DS.Ink.mintDeep)
            }
        }
        .task { await loadTree() }
    }

    // 状态行：点 + 案卷标题 + 轮次
    private var headerLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 8))
                .foregroundStyle(DS.Ink.amber)
            Text("待审批").font(DS.mono(11, .semibold)).foregroundStyle(DS.Ink.amber)
            Text("· \(item.workflow?.title ?? item.step.workflow_id) \(roundText)")
                .font(DS.mono(11)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private var roundText: String {
        if let w = workTree?.workflow, let r = w.meta?["round"]?.intValue, r >= 2 { return "· R\(r)" }
        return ""
    }

    // 前置检查卡
    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(checks.isEmpty ? "发送前置检查 · 无" : "发送前置检查 · \(checks.filter(\.failed).isEmpty ? "\(checks.count)/\(checks.count) 通过" : "有未过项")")
                .font(DS.text(13, .bold))
                .foregroundStyle(checks.filter(\.failed).isEmpty && !checks.isEmpty ? DS.Ink.done : (checks.isEmpty ? .secondary : DS.Ink.rose))
            ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: c.failed ? "xmark" : "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(c.failed ? DS.Ink.rose : DS.Ink.done)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(DS.mono(11))
                        if let d = c.detail, !d.isEmpty {
                            Text(d).font(DS.mono(10)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            if checkFailed {
                Text("前置检查未通过 — 请驳回回修，不要批准")
                    .font(DS.mono(11, .semibold)).foregroundStyle(DS.Ink.rose)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 将发送的正文（内联全文优先，契约/fallback 兜底）
    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("将发送的正文").font(DS.text(13, .bold))
            let text = item.step.bodyInline ?? item.step.fallbackBody
            if let text {
                Text(text)
                    .font(DS.text(12))
                    .lineLimit(bodyExpanded ? nil : 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(red: 1.0, green: 0.973, blue: 0.941)) // #FFF8F0
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button(bodyExpanded ? "收起" : "展开全文 ▾") {
                    withAnimation(DS.snappy) { bodyExpanded.toggle() }
                }
                .font(DS.mono(11, .semibold)).foregroundStyle(DS.Ink.mintDeep)
            } else if item.step.bodyRef != nil {
                ContentRow(label: "待批正文", name: item.step.bodyRef!.name, bytes: nil) {
                    previewTarget = PreviewTarget(id: item.step.bodyRef!.id, name: item.step.bodyRef!.name)
                }
            } else {
                Text("正文以工件形式随交付物列表展示").font(DS.mono(10)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 随信附件
    private var attachmentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("随信附件（\(item.step.deliverableItems.count)）")
                .font(DS.mono(11, .bold)).foregroundStyle(DS.Ink.mintDeep)
            ForEach(Array(item.step.deliverableItems.enumerated()), id: \.offset) { _, d in
                if let id = d.id, !(item.step.bodyRef != nil && d.viewRole == "body") {
                    ContentRow(label: d.viewRole == "body" ? "正文" : "交付物", name: d.name, bytes: d.bytes) {
                        previewTarget = PreviewTarget(id: id, name: d.name)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var noteCard: some View {
        TextField("备注（可选，随决定入档）…", text: $note, axis: .vertical)
            .font(DS.text(12))
            .lineLimit(1...3)
            .padding(12)
            .background(DS.Canvas.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func workbenchError(_ msg: String) -> some View {
        Text(msg)
            .font(DS.mono(11)).foregroundStyle(DS.Ink.rose)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Ink.rose.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // 吸底决策三键（板 03 规格）
    private var decisionBar: some View {
        HStack(spacing: 12) {
            Button {
                showRework = true
            } label: {
                Label("驳回", systemImage: "arrow.uturn.backward")
                    .font(DS.text(13, .semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Ink.rose)
            .background(DS.Canvas.card)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.910, green: 0.780, blue: 0.761), lineWidth: 1)) // #E8C7C2
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(busy)
            .accessibilityLabel("驳回二选一")

            Button {
                showAlign = true
            } label: {
                Label("对齐", systemImage: "square.and.pencil")
                    .font(DS.text(13, .semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Ink.amber)
            .background(DS.Canvas.card)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.918, green: 0.851, blue: 0.690), lineWidth: 1)) // #EAD9B0
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(busy)
            .accessibilityLabel("对齐修正")

            Button {
                act("approve")
            } label: {
                Group {
                    if busy { ProgressView().tint(.white) }
                    else { Label("批准 →", systemImage: "arrow.right").font(DS.text(13, .bold)) }
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(DS.Ink.mint)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(busy || checkFailed)
            .accessibilityLabel("批准")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(DS.Canvas.card)
        .overlay(alignment: .top) { Divider() }
    }

    private func act(_ action: String) {
        guard action == "approve" else { return }
        busy = true
        Task {
            do {
                try await APIClient.shared.gateAction(stepID: item.step.id, action: "approve", note: note)
                dismiss()
                await vm.refresh()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    private func loadTree() async {
        if let wf = item.workflow {
            workTree = try? await APIClient.shared.fetchWorkflowTree(wf.id)
        }
    }
}
