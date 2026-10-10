import Foundation

@MainActor
final class APIClient: NSObject {
    static let shared = APIClient()
    private let config = Config.shared

    lazy var urlSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    func authedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Keep-alive connections through the frp tunnel can go zombie after
        // a backend restart; the 60s default timeout freezes a view for a
        // minute. Fail fast — the poller retries within seconds.
        request.timeoutInterval = 15
        if !config.password.isEmpty {
            request.setValue("Bearer \(config.password)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func fetchSessions() async throws -> [Session] {
        let url = config.httpBaseURL.appendingPathComponent("api/sessions")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode([Session].self, from: data)
    }

    /// Skills catalog (GET /api/skills): family/purpose/dispatch health +
    /// skill_used usage aggregation (2026-10-02 retrospective phase 1 —
    /// consumed by the Agents page's second-layer entry).
    func fetchSkills() async throws -> [SkillInfo] {
        let url = config.httpBaseURL.appendingPathComponent("api/skills")
        let request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrapper: Codable { let skills: [SkillInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).skills
    }

    /// Dashboard aggregation (GET /api/stats/dashboard, wf_e86d52c97b51):
    /// tokens by calendar day + workflows by day/status/total. The query goes
    /// through URLComponents (the %3F incident wf_0c46ba361222 taught us:
    /// appendingPathComponent escapes the question mark).
    func fetchDashboardStats(days: Int) async throws -> DashboardStats {
        var comps = URLComponents(url: config.httpBaseURL.appendingPathComponent("api/stats/dashboard"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "days", value: String(days))]
        let request = authedRequest(url: comps.url!)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(DashboardStats.self, from: data)
    }

    /// Cost analysis aggregation (GET /api/lifecycle/cost-stats,
    /// wf_6a74fc4a23e4): per-job API-equivalent cost × tier bucket
    /// distribution. days=0 means all time (default is 30 days).
    func fetchCostStats(days: Int) async throws -> CostStats {
        var comps = URLComponents(url: config.httpBaseURL.appendingPathComponent("api/lifecycle/cost-stats"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "days", value: String(days))]
        let request = authedRequest(url: comps.url!)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(CostStats.self, from: data)
    }

    /// Model distribution (GET /api/usage/stats): pie chart data (byModel).
    func fetchUsageStats(hours: Int) async throws -> UsageByModel {
        var comps = URLComponents(url: config.httpBaseURL.appendingPathComponent("api/usage/stats"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "hours", value: String(hours))]
        let request = authedRequest(url: comps.url!)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(UsageByModel.self, from: data)
    }

    func createSession(name: String, workingDir: String? = nil) async throws {
        let url = config.httpBaseURL.appendingPathComponent("api/sessions")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["name": name]
        // The server reads `cwd` (app.ts POST /api/sessions) — sending
        // working_dir by mistake once caused the directory to be silently
        // dropped and every session created in the engine process's cwd
        // (2026-09-20 P2 contract alignment).
        if let dir = workingDir { body["cwd"] = dir }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await urlSession.data(for: request)
        try checkAuth(response)
    }

    func deleteSession(name: String) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let url = config.httpBaseURL.appendingPathComponent("api/sessions/\(encoded)")
        var request = authedRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await urlSession.data(for: request)
        try checkAuth(response)
    }

    // ── Intake chat: clarify loop → confirm intake (the startTask front
    // door). The event stream does not go through here — the server mirrors
    // turn events into /ws/chat (chatWSURL).

    /// Send one turn to the intake assistant. `voice` flags the turn as
    /// coming from speech transcription (the server switches to a spoken-style
    /// prompt: short sentences, no markdown — the reply will be read aloud).
    /// The timeout is relaxed to 120s for this call alone: multi-round LLM
    /// turns (look up customer / open jobs + reply) measured at 30s+; the
    /// global 15s fail-fast policy would cut the turn in half (0929 TestFlight
    /// first-use evidence) — every other API stays at 15s.
    func sendIntakeTurn(text: String, voice: Bool = false, attachments: [ChatAttachment] = []) async throws {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/intake/turn")
        var request = authedRequest(url: url)
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["input": text]
        if voice { payload["voice"] = true }
        if !attachments.isEmpty {
            payload["attachments"] = attachments.map { ["id": $0.id, "name": $0.name, "mime": $0.mime, "bytes": $0.bytes, "path": $0.path ?? ""] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                throw APIClientError.unauthorized
            }
            throw APIClientError.badResponse
        }
    }

    /// Confirm the staged plan → the server's startTask dispatches the job
    /// (the response flows back via /ws/chat dispatched/system events; the VM
    /// does not parse the return body).
    func confirmIntakePlan(autoApprove: Bool = false) async throws {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/intake/confirm")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        // Per-job auto-approve (2026-10-07): the plan-card checkbox rides into meta with confirm (default false for old callers).
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["auto_approve": autoApprove])
        _ = try await urlSession.data(for: request)
    }

    /// Per-workflow auto-approve toggle (2026-10-07): on=true immediately triggers a sweep round.
    func setAutoApprove(workflowId: String, on: Bool) async throws {
        let encoded = workflowId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowId
        let url = config.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(encoded)/auto-approve")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["on": on])
        _ = try await urlSession.data(for: request)
    }

    /// Cancel the staged plan → back to the discussion.
    func denyIntakePlan() async throws {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/intake/deny")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        _ = try await urlSession.data(for: request)
    }

    /// Reconnect recovery: pull the intake state (phase + the staged plan
    /// card). The transcript is UI state and is not returned — reopening an
    /// empty thread is acceptable (the conversation does not enter the
    /// ledger).
    func fetchIntakeState() async throws -> IntakeState {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/intake/state")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(IntakeState.self, from: data)
    }

    /// Registers this device's APNs push token with the makro backend so the
    /// Mac can send it push notifications when an agent finishes.
    func registerDeviceToken(deviceID: String, token: String) async throws {
        let url = config.httpBaseURL.appendingPathComponent("api/device-token")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID,
            "token": token,
        ])
        let (_, response) = try await urlSession.data(for: request)
        try checkAuth(response)
    }

    // MARK: - Artifacts

    /// Lists artifacts. session == nil (or empty) asks the backend for ALL
    /// sessions; a specific name filters to that session only.
    func fetchArtifacts(session: String?) async throws -> [Artifact] {
        var urlString = "\(config.httpBaseURL.absoluteString)/api/artifacts"
        if let session, !session.isEmpty {
            let encoded = session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session
            urlString += "?session=\(encoded)"
        }
        let url = URL(string: urlString)!
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode([Artifact].self, from: data)
    }

    /// Downloads the raw bytes of an artifact (HTML content for local WKWebView
    /// loading, or a video for local AVPlayer playback). Loading locally avoids
    /// the self-signed TLS problem that WKWebView/AVPlayer hit on remote fetch.
    func fetchArtifactContent(session: String, path: String) async throws -> Data {
        let encSession = session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session
        let encPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = URL(string: "\(config.httpBaseURL.absoluteString)/api/artifact?session=\(encSession)&path=\(encPath)")!
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return data
    }

    /// Shares an artifact: backend mints a 1h HMAC-signed link for the ledger
    /// artifact (`POST /api/artifact/share` JSON `{id}` → `{url, expires_in_sec}`;
    /// app.ts is the only implementation; iOS aligns with the server
    /// contract, 2026-09-20 P2). The `id` comes from the ledger id on
    /// /api/artifacts rows (legacy hub files have no id and cannot be
    /// shared).
    func shareArtifact(id: String) async throws -> ShareResult {
        let url = config.httpBaseURL.appendingPathComponent("api/artifact/share")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id])
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
        return try JSONDecoder().decode(ShareResult.self, from: data)
    }

    func checkAuth(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            throw APIClientError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIClientError.badResponse
        }
    }

    /// Auth check that carries the server's error body through — 4xx/5xx
    /// responses here carry actionable reasons ("a rejection must state what to change"…).
    /// New/edited call sites should prefer this over bare checkAuth.
    func checkAuthData(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            throw APIClientError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIClientError.http(status: http.statusCode, body: Self.errorBody(data))
        }
    }

    private static func errorBody(_ data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["error"] as? String, !msg.isEmpty else { return nil }
        return msg
    }
}

// MARK: - Share result

/// Response from POST /api/artifact/share — the HMAC-signed, 1h-expiry link for
/// the ledger artifact. Server contract: `{url, expires_in_sec}` (app.ts:921).
struct ShareResult: Codable {
    let url: String
    let expires_in_sec: Int?
}

extension APIClient: URLSessionDelegate {
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Config.handleTLSChallenge(challenge, completionHandler: completionHandler)
    }
}

/// GET /api/chat/intake/state response: used for reconnect recovery (the transcript is UI state and is not returned).
struct IntakeState: Codable {
    let phase: String
    let plan: PendingPlan?
}

enum APIClientError: LocalizedError {
    case badResponse
    case unauthorized
    /// Non-2xx with the server's error body — the actionable reason wins.
    case http(status: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Server error"
        case .unauthorized: return "Wrong password"
        case .http(_, let body):
            if let body { return body }
            return "Server error"
        }
    }
}

// MARK: - Chat history pull (wf_e2f2bfba8865 P0: backfilling frames missed during suspension)

struct ChatEventFrame: Decodable {
    let type: String
    let data: String
    let at: String?
}

struct ChatHistoryResponse: Decodable {
    let history: [ChatEventFrame]
}

extension APIClient {
    func fetchChatHistory() async throws -> [ChatEventFrame] {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/history")
        var request = authedRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(ChatHistoryResponse.self, from: data).history
    }
}

// MARK: - Chat attachment upload + turn carry (wf_3310501a9fe4, 2026-10-05)

extension APIClient {
    /// Upload one attachment as multipart → the server fills in {id,name,mime,bytes,path}.
    func uploadChatAttachment(data: Data, name: String, mime: String) async throws -> ChatAttachment {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/attachment")
        var request = authedRequest(url: url)
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        let boundary = "mk\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (respData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.badResponse }
        if http.statusCode == 401 { throw APIClientError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            if let msg = try? JSONDecoder().decode([String: String].self, from: respData)["error"] {
                throw APIClientError.http(status: http.statusCode, body: msg)
            }
            throw APIClientError.http(status: http.statusCode, body: nil)
        }
        return try JSONDecoder().decode(ChatAttachment.self, from: respData)
    }
}
