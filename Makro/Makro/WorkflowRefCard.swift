import SwiftUI

// chat 内任务单引用卡（2026-10-04，wf_8bbd5a47b528）：消息文本里出现单子 ID
// （wf_ + 12 位十六进制）即在气泡下渲染卡片——标题/状态一眼可见，点卡经
// DeepLinkRouter.artifactsProducer 深链到 Artifacts 过滤视图（MakroApp 已
// 订阅该值自动切 tab；ArtifactsView 按 session=wfId 过滤，芯片显示案卷名，
// 与 MeshNodeRow 产物芯片同一机制）。

enum WorkflowRef {
    /// wf_ + 12 位十六进制；去重保序（一条消息提到同一单多次只出一张卡）。
    static func ids(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "wf_[0-9a-f]{12}") else { return [] }
        let ns = text as NSString
        var seen: Set<String> = []
        var out: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let id = ns.substring(with: m.range)
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}

/// 树缓存跨卡共享（R1 P2-9）：长会话同一 wfID 随多条消息各渲染一张卡，旧实现
/// 每卡 .task 各自打一次 /api/workflow/:id/tree——进程级按 wfID 缓存 + 60s
/// TTL（running 状态不能永久陈旧），窗口内同一单至多一次真实请求。
@MainActor
enum WorkflowTreeCache {
    private static var store: [String: (tree: LifecycleWorkflowTree, at: Date)] = [:]
    private static let ttl: TimeInterval = 60

    static func get(_ id: String) -> LifecycleWorkflowTree? {
        guard let e = store[id], Date().timeIntervalSince(e.at) < ttl else { return nil }
        return e.tree
    }

    static func put(_ id: String, _ tree: LifecycleWorkflowTree) {
        store[id] = (tree, Date())
    }
}

struct WorkflowRefCard: View {
    let wfID: String
    /// 「➕ 跟进」（2026-10-04，wf_9d93ee9f7adb）：基于该单创建 follow-up——
    /// 回调携 (wfID, 原单标题)，ChatView 预填输入框（含原单上下文）后仍走
    /// 既有「计划卡确认才开单」流程，不旁路。
    var onFollow: ((String, String) -> Void)? = nil
    @State private var tree: LifecycleWorkflowTree?
    @State private var failed = false
    // 单子详情入口（wf_1b3f9eaa55f9）：复用 AgentsView 案卷卡同款 sheet。
    @StateObject private var caseVM = LifecycleViewModel()
    @State private var showDetail = false

    private var wf: LifecycleWorkflow? { tree?.workflow }

    /// 状态色（与 Flow 面板口径一致）：进行中呼吸蓝，完成绿，失败红，取消灰。
    private var statusColor: Color {
        switch wf?.status {
        case "running", "queued": return DS.Ink.mint
        case "completed": return DS.Ink.done
        case "failed": return DS.Ink.rose
        case "cancelled": return DS.Ink.zinc
        default: return DS.Ink.zinc
        }
    }

    private var statusLabel: String {
        switch wf?.status {
        case "running": return "Running"
        case "queued": return "Queued"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        default: return "…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 信息行（点=产物，保持原主点击习惯）
            Button {
                // 同 MeshNodeRow 产物芯片：置 producer → MakroApp 切 Artifacts tab，
                // ArtifactsView 按 session=wfId 过滤出该单全部产物。
                DeepLinkRouter.shared.artifactsProducer = wfID
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Ink.mintDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failed ? "Job \(wfID)" : (wf?.title ?? "Loading job…"))
                            .font(DS.text(13.5, .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(wfID)
                            .font(DS.mono(10, .regular))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                            .breathing(wf?.status == "running")
                        Text(statusLabel)
                            .font(DS.mono(10, .semibold))
                            .foregroundStyle(statusColor)
                    }
                    if let onFollow {
                        Button {
                            onFollow(wfID, wf?.title ?? "")
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Follow up")
                                    .font(DS.mono(10, .semibold))
                            }
                            .foregroundStyle(DS.Ink.mintDeep)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(DS.Ink.mint.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Create a follow-up from job \(wf?.title ?? wfID)")
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open artifacts of job \(wf?.title ?? wfID)")

            // 三导航入口（wf_430649acd604）：📋 Workflow 过程 / 🗂 Artifact 结果 /
            // 👤 Agents 执行现场（该单 resolved session 的终端——谁在干、干到哪）。
            HStack(spacing: 7) {
                Button {
                    Task { await caseVM.select(wfID) }
                    showDetail = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Details")
                            .font(DS.text(12, .semibold))
                    }
                    .foregroundStyle(DS.Ink.mintDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(DS.Ink.mint.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View job \(wf?.title ?? wfID) details")

                Button {
                    DeepLinkRouter.shared.artifactsProducer = wfID
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Artifacts")
                            .font(DS.text(12, .semibold))
                    }
                    .foregroundStyle(DS.Ink.mintDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(DS.Ink.mint.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open artifacts of job \(wf?.title ?? wfID)")

                Button {
                    // 执行现场：DeepLinkRouter.session → Agents tab + path=[session]
                    // 直达该会话终端（AgentsView 现成 replay 机制）。
                    if let s = wf?.session, !s.isEmpty {
                        DeepLinkRouter.shared.session = s
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.wave.2")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(wf?.session?.isEmpty == false ? "Live" : "Not dispatched")
                            .font(DS.text(12, .semibold))
                    }
                    .foregroundStyle((wf?.session?.isEmpty == false) ? DS.Ink.mintDeep : Color.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(DS.Ink.mint.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(wf?.session?.isEmpty != false)
                .accessibilityLabel("View the live execution of job \(wf?.title ?? wfID)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DS.Canvas.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                .stroke(DS.Ink.mint.opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showDetail) {
            WorkflowDetailSheet(vm: caseVM, workflowID: wfID)
                .presentationDetents([.large])
        }
        .task {
            guard tree == nil, !failed else { return }
            // R1 P2-9：先查跨卡缓存，命中不打 API；未命中拉取成功后回写。
            if let cached = WorkflowTreeCache.get(wfID) {
                tree = cached
                return
            }
            do {
                let t = try await APIClient.shared.fetchWorkflowTree(wfID)
                tree = t
                WorkflowTreeCache.put(wfID, t)
            } catch {
                failed = true // 查不到（已清理/打错）：卡降级为纯 ID + 跳转仍可用
            }
        }
    }
}
