import Foundation

// Lifecycle (V2 pipeline) endpoints, isolated in an extension so the core
// client file stays untouched. Same request plumbing as the main class.
extension APIClient {

    func fetchGateQueue() async throws -> [GateQueueItem] {
        let url = Config.shared.httpBaseURL
            .appendingPathComponent("api/lifecycle/steps")
            .appending(queryItems: [
                URLQueryItem(name: "status", value: "waiting_human"),
                URLQueryItem(name: "limit", value: "30"),
            ])
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrap: Codable { let steps: [GateQueueItem] }
        return try JSONDecoder().decode(Wrap.self, from: data).steps
    }

    func fetchWorkflows(limit: Int = 50) async throws -> [LifecycleWorkflow] {
        // POST-list on the alias path: a cache layer in some mobile networks
        // served stale GET bodies for the canonical URL (live-marker probes
        // proved body substitution); POST responses are never cached.
        let url = Config.shared.httpBaseURL
            .appendingPathComponent("api/lifecycle/workflows2")
            .appending(queryItems: [URLQueryItem(name: "limit", value: String(limit))])
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrap: Codable { let workflows: [LifecycleWorkflow] }
        return try JSONDecoder().decode(Wrap.self, from: data).workflows
    }

    func fetchWorkflowTree(_ id: String) async throws -> LifecycleWorkflowTree {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(encoded)")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(LifecycleWorkflowTree.self, from: data)
    }

    /// action: approve | deny | retry
    /// 驳回回修:feedback 注入前一步重做,轮次+1,流程不断。
    func reworkStep(stepID: String, feedback: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/rework")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["feedback": feedback, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 一等插话：向在途 agent/verify 步递补充指示——投递+留痕一体
    /// （step 干预史、output.activity、step_intervened 事件）。区别于
    /// /api/sessions/:name/send 的裸 tmux send-keys。
    func interveneStep(stepID: String, text: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/intervene")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 对齐修正:人定稿的最高优先修正,以 amendment artifact 入档,流程继续。
    func alignStep(stepID: String, amendment: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/align")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["amendment": amendment, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 免模板发单（与 web #/trigger 同一契约）：startTask 发单即接手，
    /// 首节点自动播种；返回 {workflow:{id,...}}（裸 camelCase，只取 id）。
    /// relatesTo：跟进单挂靠（input.relates_to → 因果链入账）。
    func startTask(title: String, brief: String, relatesTo: String? = nil) async throws -> String {
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/tasks")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var input: [String: Any] = ["brief": brief]
        if let r = relatesTo, !r.isEmpty { input["relates_to"] = r }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "input": input,
        ])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
        struct Wrap: Codable { struct WF: Codable { let id: String }; let workflow: WF }
        return try JSONDecoder().decode(Wrap.self, from: data).workflow.id
    }

    // MARK: - 案卷级动作（web lifecycle.ts 对齐）



    /// 办结：nodes 模式跑完动作后显式结算（running 且无在飞步）。
    func settleWorkflow(_ id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(encoded)/settle")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 失败收口：failed 案卷正式关闭（区别于 running 的 force-close）。
    func closeWorkflow(_ id: String, note: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(encoded)/close")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["note": note, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 定时发送：批准发送闸门并指定 send_at（ISO8601）。
    func approveScheduled(stepID: String, sendAt: Date, note: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/approve")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "note": note, "by": "iphone", "send_at": ISO8601DateFormatter().string(from: sendAt),
        ])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 单步取消（不牵连整单）：仅 pending / waiting_human 步合法。
    func cancelStep(stepID: String, note: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/cancel")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["note": note, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 补正重发：send 守卫拒发后，agent 补正再过闸重发。
    func reworkSend(stepID: String, feedback: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/rework-send")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["feedback": feedback, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 重试并改指令：retry 携 plan 覆写（agent/verify 失败步）。
    func retryWithPatch(stepID: String, plan: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/retry")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "note": "iphone retried with new instructions", "by": "iphone", "plan": plan,
        ])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 补料候选：GET 返回顶层 Record<key,{value,source}>（与 web 同形状）。
    func fetchAmendSuggestions(workflowID: String) async throws -> [AmendSuggestion] {
        let encoded = workflowID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(encoded)/amend-suggestions")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Suggestion: Codable { let value: JSONValue?; let source: String? }
        let raw = try JSONDecoder().decode([String: Suggestion].self, from: data)
        return raw.map { key, s in
            AmendSuggestion(key: key,
                            value: s.value?.stringValue ?? s.value.map { "\($0.numberValue ?? 0)" } ?? "",
                            source: s.source ?? "")
        }.sorted { $0.key < $1.key }
    }

    /// 补料：patch 合并进步 input 后自动重跑。
    func amendStep(stepID: String, patch: [String: String]) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/amend")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["patch": patch, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    /// 强制关闭 running 流水（终局逃生舱）：在途步全部 cancelled，流水终局。
    func forceCloseWorkflow(_ id: String, note: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(encoded)/force-close")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["note": note, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }

    func gateAction(stepID: String, action: String, note: String) async throws {
        let encoded = stepID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stepID
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/steps/\(encoded)/\(action)")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["note": note, "by": "iphone"])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
    }
}

extension URL {
    func appending(queryItems items: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        var query = comps.queryItems ?? []
        query.append(contentsOf: items)
        comps.queryItems = query
        return comps.url!
    }
}

// MARK: - Case Artifacts

extension APIClient {
    func fetchCaseArtifacts(workflowID: String) async throws -> [CaseArtifact] {
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(workflowID)/artifacts")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrap: Codable { let artifacts: [CaseArtifact] }
        return try JSONDecoder().decode(Wrap.self, from: data).artifacts
    }

    /// Authenticated byte fetch for a case artifact (GET /api/artifacts/{id}/content).
    /// In-app only: the endpoint needs the Bearer token and sits behind the
    /// self-signed TLS pair, so link-out to Safari can never render it.
    func fetchCaseArtifactContent(id: String) async throws -> Data {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/artifacts/\(encoded)/content")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return data
    }

    @discardableResult
    func purgeCaseArtifacts(workflowID: String) async throws -> Int {
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(workflowID)/artifacts/purge")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
        struct Wrap: Codable { let purged: Int }
        return (try? JSONDecoder().decode(Wrap.self, from: data).purged) ?? 0
    }
}

// MARK: - Agent Profiles

extension APIClient {
    struct AgentProfileView: Codable, Identifiable, Equatable {
        let name: String
        var project: String?
        var runtime: String?
        var cwd: String?
        var model: String?
        var launch_cmd: String?
        var prompt_brief: String?
        var updated_at: Int64?
        var id: String { name }
    }

    func fetchAgentProfiles() async throws -> [AgentProfileView] {
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/agents/profiles")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrap: Codable { let profiles: [AgentProfileView] }
        return try JSONDecoder().decode(Wrap.self, from: data).profiles
    }

    // ── Agent Mesh（板E）：一张活图的移动投影 ──────────────────────────────
    // nodes=声明展开（company/domain/绑定 senders），recent=账本 route_decision
    // 回放。视图零自有状态：维度切换=同一份数据重排，另一维变成节点标签。

    struct MeshNode: Codable, Identifiable, Equatable {
        let name: String
        let clone_of: String?
        let company: String?
        let domain: String?
        let bind_senders: [String]?
        let cwd: String?
        let agent: String?
        let working: Bool?
        let live: Bool?
        var id: String { name }
        var isClone: Bool { clone_of != nil }
        var isBound: Bool { !(bind_senders ?? []).isEmpty }
    }

    struct MeshRoute: Codable, Identifiable, Equatable {
        let id: Int64
        let ts: String
        let workflow: String?
        let from: String?
        let company: String?
        let domain: String?
        let session: String?
        let fallback: Bool?
    }

    struct AgentsGraph: Equatable {
        let defaultSession: String
        let companies: [String]
        let domains: [MeshDomain]
        let nodes: [MeshNode]
        let recent: [MeshRoute]
        struct MeshDomain: Equatable { let company: String; let name: String }
    }

    /// 路由事件回放（/api/lifecycle/events 账本行的路由子集）——路由 DAG 的边料。
    func fetchRouteEvents(limit: Int = 1000) async throws -> [RouteEvent] {
        // query 必须走 URLComponents——appendingPathComponent 会把 "?" 转义成
        // %3F（实发 /events%3Flimit=1000 → 404 → 前端误报 Server error，
        // 2026-10-01 neo 报障 wf_0c46ba361222 实证，引擎日志 [http-warn] 留痕）。
        var comps = URLComponents(url: Config.shared.httpBaseURL.appendingPathComponent("api/lifecycle/events"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let url = comps.url!
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrap: Codable { let events: [Row] }
        struct Row: Codable {
            let id: Int64
            let type: String
            let entityId: String?
            let payload: Payload?
            struct Payload: Codable {
                let from: String?
                let session: String?
                let requested: String?
                let resolved: String?
                let workflow_id: String?
            }
        }
        let w = try JSONDecoder().decode(Wrap.self, from: data)
        return w.events.map { e in
            RouteEvent(id: e.id, type: e.type,
                       from: e.payload?.from,
                       session: e.payload?.session,
                       requested: e.payload?.requested,
                       resolved: e.payload?.resolved)
        }
    }

    func fetchAgentsGraph() async throws -> AgentsGraph {
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/agents/graph")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrap: Codable {
            let default_session: String
            let companies: [String]
            let domains: [MeshDomainWrap]
            let nodes: [MeshNode]
            let recent: [MeshRoute]
            struct MeshDomainWrap: Codable { let company: String; let name: String }
        }
        let w = try JSONDecoder().decode(Wrap.self, from: data)
        return AgentsGraph(
            defaultSession: w.default_session,
            companies: w.companies,
            domains: w.domains.map { .init(company: $0.company, name: $0.name) },
            nodes: w.nodes,
            recent: w.recent
        )
    }
}

/// 补料候选行（amend-suggestions）。
struct AmendSuggestion: Identifiable, Equatable {
    let key: String
    let value: String
    let source: String
    var id: String { key }
}
