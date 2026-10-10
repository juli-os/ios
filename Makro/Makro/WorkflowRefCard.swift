import SwiftUI

// In-chat work-order reference card (2026-10-04, wf_8bbd5a47b528): when a
// job ID (wf_ + 12 hex digits) appears in message text, render a card under
// the bubble — title/status visible at a glance; tapping the card deep-links
// via DeepLinkRouter.artifactsProducer to the Artifacts filtered view
// (MakroApp already subscribes to that value and switches tabs;
// ArtifactsView filters by session=wfId, the chip shows the case name — the
// same mechanism as the MeshNodeRow artifact chip).

enum WorkflowRef {
    /// wf_ + 12 hex digits; deduplicated, order kept (a message mentioning the same job repeatedly yields one card).
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

/// Tree cache shared across cards (R1 P2-9): in a long session the same
/// wfID renders one card per message, and the old implementation had each
/// card's .task hit /api/workflow/:id/tree on its own — a process-level
/// per-wfID cache + 60s TTL (a running state must not go permanently
/// stale); at most one real request per job within the window.
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
    /// "➕ Follow-up" (2026-10-04, wf_9d93ee9f7adb): create a follow-up based
    /// on this job — the callback carries (wfID, original title); ChatView
    /// prefills the input box (with the original job's context) and still
    /// goes through the existing "confirm on the plan card to start" flow,
    /// no bypass.
    var onFollow: ((String, String) -> Void)? = nil
    @State private var tree: LifecycleWorkflowTree?
    @State private var failed = false
    // Job detail entry (wf_1b3f9eaa55f9): reuses the same sheet as the AgentsView case card.
    @StateObject private var caseVM = LifecycleViewModel()
    @State private var showDetail = false

    private var wf: LifecycleWorkflow? { tree?.workflow }

    /// Status colors (same basis as the Flow panel): running breathing blue, completed green, failed red, cancelled gray.
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
            // Info row (tap = artifacts, keeping the original primary-tap habit)
            Button {
                // Same as the MeshNodeRow artifact chip: set producer →
                // MakroApp switches to the Artifacts tab; ArtifactsView
                // filters by session=wfId to all of that job's artifacts.
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

            // Three navigation entries (wf_430649acd604): 📋 the Workflow
            // process / 🗂 Artifact outcomes / 👤 the Agents work scene (the
            // terminal of the job's resolved session — who is working, and
            // how far).
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
                    // Work scene: DeepLinkRouter.session → Agents tab +
                    // path=[session] goes straight to that session's terminal
                    // (AgentsView's existing replay mechanism).
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
            // R1 P2-9: check the cross-card cache first — a hit skips the API; on a miss, write back after a successful fetch.
            if let cached = WorkflowTreeCache.get(wfID) {
                tree = cached
                return
            }
            do {
                let t = try await APIClient.shared.fetchWorkflowTree(wfID)
                tree = t
                WorkflowTreeCache.put(wfID, t)
            } catch {
                failed = true // not found (purged / typo): the card degrades to the bare ID + navigation still works
            }
        }
    }
}
