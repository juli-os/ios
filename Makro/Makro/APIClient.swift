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

    /// 技能目录（GET /api/skills）：家族/用途/分发健康 + skill_used 用量聚合
    /// （2026-10-02 追溯一期——Agents 页第二层入口消费）。
    func fetchSkills() async throws -> [SkillInfo] {
        let url = config.httpBaseURL.appendingPathComponent("api/skills")
        let request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        struct Wrapper: Codable { let skills: [SkillInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).skills
    }

    /// Dashboard 聚合（GET /api/stats/dashboard，wf_e86d52c97b51）：token
    /// 自然日 + workflow 按日/状态/总量。query 走 URLComponents（%3F 事故
    /// wf_0c46ba361222 教训：appendingPathComponent 会转义问号）。
    func fetchDashboardStats(days: Int) async throws -> DashboardStats {
        var comps = URLComponents(url: config.httpBaseURL.appendingPathComponent("api/stats/dashboard"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "days", value: String(days))]
        let request = authedRequest(url: comps.url!)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(DashboardStats.self, from: data)
    }

    /// 费用分析聚合（GET /api/lifecycle/cost-stats，wf_6a74fc4a23e4）：每单
    /// API 等效成本 × 价位分桶分布。days=0 表示全部（默认 30 天）。
    func fetchCostStats(days: Int) async throws -> CostStats {
        var comps = URLComponents(url: config.httpBaseURL.appendingPathComponent("api/lifecycle/cost-stats"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "days", value: String(days))]
        let request = authedRequest(url: comps.url!)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuth(response)
        return try JSONDecoder().decode(CostStats.self, from: data)
    }

    /// 模型分布（GET /api/usage/stats）：饼图数据（byModel）。
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
        // 服务端读 `cwd`（app.ts POST /api/sessions）——曾错发 working_dir 导致
        // 目录被静默丢弃、会话全建在引擎进程 cwd（2026-09-20 P2 契约对齐）。
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

    // ── 开单对话（chat intake）：clarify loop → 确认开单（startTask 正门）──
    // 事件流不走这里——服务端把回合事件镜像进 /ws/chat（chatWSURL）。

    /// 发一轮消息给开单助手。`voice` 标记本轮来自语音转写（服务端换口语
    /// 化提示词：短句、无 markdown——回复会被朗读）。
    /// 超时单独放宽到 120s：LLM 多轮（查客户/在办单+回复）实测 30s+，
    /// 全局 15s 快速失败策略会把回合腰斩（0929 TestFlight 首用实证）——
    /// 其余 API 仍 15s。
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

    /// 确认暂存中的计划 → 服务端 startTask 开单（响应经 /ws/chat 的
    /// dispatched/system 事件回流，VM 不解析返回体）。
    func confirmIntakePlan(autoApprove: Bool = false) async throws {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/intake/confirm")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        // 本单免批（2026-10-07）：计划卡勾选随 confirm 进 meta（缺省 false 兼容旧调用）。
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["auto_approve": autoApprove])
        _ = try await urlSession.data(for: request)
    }

    /// 单子级免批切换（2026-10-07）：on=true 立即触发一轮 sweep。
    func setAutoApprove(workflowId: String, on: Bool) async throws {
        let encoded = workflowId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowId
        let url = config.httpBaseURL.appendingPathComponent("api/lifecycle/workflows/\(encoded)/auto-approve")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["on": on])
        _ = try await urlSession.data(for: request)
    }

    /// 取消暂存中的计划 → 回到讨论。
    func denyIntakePlan() async throws {
        let url = config.httpBaseURL.appendingPathComponent("api/chat/intake/deny")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        _ = try await urlSession.data(for: request)
    }

    /// 重连恢复：拉 intake 状态（phase + 暂存计划卡）。transcript 是 UI
    /// 态不回传——重开空线程可接受（对话不进账）。
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
    /// app.ts 为唯一实现，iOS 以服务端契约为准对齐，2026-09-20 P2）。
    /// `id` 来自 /api/artifacts 行的账本 id（legacy 中心库文件无 id，不可分享）。
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
    /// responses here carry actionable reasons ("驳回必须写明修改意见"…).
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

/// GET /api/chat/intake/state 的响应：重连恢复用（transcript 是 UI 态不回传）。
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

// MARK: - Chat history 回拉（wf_e2f2bfba8865 P0：挂起期错过的帧补显）

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

// MARK: - Chat 附件上传 + turn 携带（wf_3310501a9fe4，2026-10-05）

extension APIClient {
    /// multipart 上传单件附件 → 服务端回填 {id,name,mime,bytes,path}。
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
