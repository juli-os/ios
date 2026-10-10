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
    /// Reject & rework: the feedback is injected and the previous step re-runs; round +1, the flow is not cut.
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

    /// First-class intervene: supplementary instructions delivered to an
    /// in-flight agent/verify step — delivery + record in one (step
    /// intervention history, output.activity, step_intervened events).
    /// Distinct from the bare tmux send-keys of /api/sessions/:name/send.
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

    /// Course amendment: the highest-priority correction in the human's final wording, filed as an amendment artifact; the flow continues.
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

    /// Template-free intake (same contract as the web #/trigger):
    /// startTask dispatches and takes over, the first node auto-seeded;
    /// returns {workflow:{id,...}} (bare camelCase, we take only the id).
    /// relatesTo: follow-up attachment (input.relates_to → enters the causal
    /// chain on the ledger).
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

    // MARK: - Case-level actions (aligned with the web lifecycle.ts)



    /// Settle: explicit settlement after nodes-mode actions finish (running with no in-flight steps).
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

    /// Failed close-out: formally closes a failed case (distinct from force-close for running ones).
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

    /// Scheduled send: approves the send gate with a send_at (ISO8601).
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

    /// Cancel one step (the whole job unaffected): only pending / waiting_human steps are legal.
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

    /// Amend & resend: after the send guard refuses, the agent amends and re-enters the gate to resend.
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

    /// Retry with new instructions: retry carrying a plan override (failed agent/verify steps).
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

    /// Amend-input candidates: the GET returns a top-level Record<key,{value,source}> (same shape as the web).
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

    /// Amend inputs: the patch merges into the step input, then it auto-reruns.
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

    /// Force-close a running pipeline (terminal escape hatch): all in-flight steps cancelled, the pipeline ends.
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

    // ── Agent Mesh (board E): the mobile projection of a living graph ──────
    // nodes = declaration expansion (company/domain/bound senders), recent =
    // ledger route_decision replay. The view owns zero state of its own:
    // switching dimensions is a re-sort of the same data; the other dimension
    // becomes node labels.

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

    /// Routing event replay (the routing subset of /api/lifecycle/events ledger rows) — edge material for the routing DAG.
    func fetchRouteEvents(limit: Int = 1000) async throws -> [RouteEvent] {
        // The query must go through URLComponents — appendingPathComponent
        // escapes "?" into %3F (actually sent /events%3Flimit=1000 → 404 →
        // the front end falsely reported Server error; confirmed by the
        // 2026-10-01 neo report wf_0c46ba361222, with the engine log's
        // [http-warn] trace).
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

/// Amend-input candidate row (amend-suggestions).
struct AmendSuggestion: Identifiable, Equatable {
    let key: String
    let value: String
    let source: String
    var id: String { key }
}
