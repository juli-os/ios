import Foundation

// Feedback intake (2026-09-28 bootstrapped: quick feedback from the phone).
// Goes through the juli-service channel (POST /api/feedback-self/submit —
// the same endpoint and the same manual semantics as the web submit card /
// floating widget: dedup kept, judgment exempted, landing only in the
// juli-dev human-review gate). The wall = a mirrored read-only surface; the
// client filters to juli's own channels (juli-service/juli-site).

struct FeedbackWallRecord: Identifiable, Codable, Equatable {
    let id: String
    let created: String
    let status: String
    let page: String
    let body: String
    let authorName: String
    let replyTo: String
    let elementLabel: String
    let source: String?
    let originKind: String?

    enum CodingKeys: String, CodingKey {
        case id, created, status, page, body
        case authorName = "author_name"
        case replyTo = "reply_to"
        case elementLabel = "element_label"
        case source
        case originKind = "origin_kind"
    }
}

struct FeedbackSubmitResult {
    let recordId: String
    let workflowId: String?
    let intakeStatus: String
}

extension APIClient {

    /// Submit feedback about juli itself → starts a job through the juli-service channel (manual semantics).
    func submitFeedback(body: String, page: String, author: String) async throws -> FeedbackSubmitResult {
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/feedback-self/submit")
        var request = authedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["body": body, "page": page, "author_name": author]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let recordId = obj["record_id"] as? String ?? ""
        let intake = obj["intake"] as? [String: Any] ?? [:]
        let workflowId = (intake["workflow"] as? [String: Any])?["id"] as? String
        return FeedbackSubmitResult(
            recordId: recordId,
            workflowId: workflowId,
            intakeStatus: intake["status"] as? String ?? ""
        )
    }

    /// Feedback wall (full mirror → the client filters to juli's own channels, newest first).
    func fetchFeedbackWall() async throws -> [FeedbackWallRecord] {
        let url = Config.shared.httpBaseURL.appendingPathComponent("api/feedback-mirror/records")
        var request = authedRequest(url: url)
        let (data, response) = try await urlSession.data(for: request)
        try checkAuthData(response, data: data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let raw = obj["records"] as? [[String: Any]] ?? []
        let decoder = JSONDecoder()
        var all: [FeedbackWallRecord] = []
        for item in raw {
            let itemData = try JSONSerialization.data(withJSONObject: item)
            if let rec = try? decoder.decode(FeedbackWallRecord.self, from: itemData) {
                all.append(rec)
            }
        }
        let filtered = all.filter { rec in
            let src = rec.source ?? "client"
            return src == "juli-service" || src == "juli-site"
        }
        return filtered.sorted { $0.created > $1.created }
    }
}
