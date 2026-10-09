import SwiftUI

// 反馈视图（2026-09-28 自举）：手机端随手给 juli 自己提反馈——提交走
// juli-service 渠道（juli-dev 处理，闸门人审），墙=juli 自有渠道镜像只读。
// 场景：出门在外/在家沙发上持续 feedback（用户实录诉求）。

struct FeedbackView: View {
    @State private var body_ = ""
    @State private var page = ""
    @State private var author = UserDefaults.standard.string(forKey: "fb_author") ?? "cyber"
    @State private var submitting = false
    @State private var result: FeedbackSubmitResult?
    @State private var errorText: String?
    @State private var wall: [FeedbackWallRecord] = []
    @State private var wallError: String?
    @State private var wallLoading = false
    @State private var showReplies = false

    var body: some View {
        NavigationStack {
            List {
                // ---- 提交卡 ----
                Section {
                    TextField("Ref (optional): page / ticket / element", text: $page)
                        .autocorrectionDisabled()
                    TextEditor(text: $body_)
                        .frame(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if body_.isEmpty {
                                Text("Issue/suggestion: expected vs actual…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        TextField("Name", text: $author)
                            .frame(maxWidth: 110)
                            .autocorrectionDisabled()
                        Spacer()
                        Button {
                            Task { await submit() }
                        } label: {
                            if submitting { ProgressView() } else { Text("Submit & open job") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
                    }
                    if let result {
                        Label(
                            result.intakeStatus == "started"
                                ? "Job opened: \(result.workflowId ?? result.recordId) — the repo stays untouched until gate approval"
                                : "No job: \(result.intakeStatus) (the record is on the wall)",
                            systemImage: result.intakeStatus == "started" ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("juli feedback")
                } footer: {
                    Text("Into the juli-service channel: the job lands in the juli-dev session, three-part artifacts pass the gate, approval edits the repo.")
                }

                // ---- 反馈墙（juli 自有渠道）----
                Section {
                    if wallLoading {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    } else {
                        if let wallError {
                            // 加载失败≠暂无记录：错误显式可见；存量记录照常展示。
                            Label("Load failed: \(wallError) (pull to retry)", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        if wall.isEmpty {
                            if wallError == nil {
                                Text("No records yet").foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(wall.filter { showReplies || $0.replyTo.isEmpty }) { rec in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(rec.status)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(statusTint(rec.status).opacity(0.15), in: Capsule())
                                        .foregroundStyle(statusTint(rec.status))
                                    if rec.replyTo.isEmpty != true {
                                        Text("Reply").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if rec.originKind == "agent" || rec.originKind == "engine" {
                                        Text("AI").font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Capsule().fill(.secondary.opacity(0.15)))
                                    }
                                    Text((rec.source ?? "") == "juli-site" ? "Site" : "Local")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                    Spacer()
                                    Text(shortTime(rec.created)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text(rec.body)
                                    .font(.subheadline)
                                    .lineLimit(3)
                                if !rec.elementLabel.isEmpty {
                                    Text(rec.elementLabel).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            }
                        }
                    }
                    Toggle("Show reply", isOn: $showReplies)
                        .font(.footnote)
                } header: {
                    Text("Feedback wall (juli channel)")
                }
            }
            .navigationTitle("Feedback")
            .refreshable { await loadWall() }
            .task { await loadWall() }
        }
    }

    private func submit() async {
        errorText = nil
        result = nil
        submitting = true
        defer { submitting = false }
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmedAuthor, forKey: "fb_author")
        do {
            let r = try await APIClient.shared.submitFeedback(
                body: body_.trimmingCharacters(in: .whitespacesAndNewlines),
                page: page.trimmingCharacters(in: .whitespaces),
                author: trimmedAuthor
            )
            result = r
            if r.intakeStatus == "started" {
                body_ = ""
                page = ""
                await loadWall()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadWall() async {
        wallLoading = true
        defer { wallLoading = false }
        do {
            let records = try await APIClient.shared.fetchFeedbackWall()
            wall = Array(records.prefix(50))
            wallError = nil
        } catch {
            // 失败不清空存量记录（旧数据仍可看），但错误必须可见，
            // 不得让墙冒充「暂无记录」。
            wallError = error.localizedDescription
        }
    }

    private func statusTint(_ s: String) -> Color {
        switch s {
        case "New": return .blue
        case "Adopted": return .orange
        case "Done": return .green
        default: return .secondary
        }
    }

    /// "2026-09-28T12:08:30.665Z" → "09-28 20:08"（北京时间）。
    private func shortTime(_ iso: String) -> String {
        var comps = String(iso.prefix(16)).split(separator: "T")
        guard comps.count == 2 else { return iso }
        let d = comps[0].suffix(5)
        guard let h = Int(comps[1].prefix(2)) else { return String(d) }
        let bj = (h + 8) % 24
        return "\(d) \(String(format: "%02d", bj))\(comps[1].dropFirst(2).prefix(3))"
    }
}
