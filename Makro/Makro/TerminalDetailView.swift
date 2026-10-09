import SwiftUI

// Terminal detail: the live pane + input bar for ONE session. No longer a
// tab of its own — it is the shared destination every agent/session row in
// the Agents tab pushes into (and Flow's "在终端打开" full-screen cover).

struct TerminalDetailView: View {
    let sessionName: String
    // Push 进入时系统返回键就是出口；fullScreenCover 进入时没有系统手势，
    // 必须自带关闭——否则用户被锁在终端里只能杀 App。
    var onClose: (() -> Void)? = nil
    @StateObject private var terminalVM = TerminalViewModel()
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    // The session actually on screen — the swipe-out drawer can switch it
    // without popping back to the grid.
    @State private var current = ""
    @State private var showDrawer = false
    @State private var drawerSessions: [Session] = []
    // profile 信息带（板 07）：cwd/model + 当前任务芯片（Agents→Flow 缝）
    @State private var profileCwd = ""
    @State private var profileModel = ""
    @State private var activeCaseTitle: String?
    @State private var activeCaseID: String?
    // 呈现态与数据态分离：loadProfileBand 只写数据；芯片点按才置呈现，
    // 否则开终端即被 sheet 盖屏 + 二次点按因值未变而失效。
    @State private var presentedCase: CaseRef?
    @StateObject private var caseVM = LifecycleViewModel()

    private struct CaseRef: Identifiable { let id: String }

    /// profile 信息带：cwd · model · 当前任务芯片（点开案卷详情）。
    @ViewBuilder
    private var profileBand: some View {
        if !profileCwd.isEmpty || activeCaseTitle != nil {
            HStack(spacing: 8) {
                if !profileCwd.isEmpty {
                    Text("\(profileCwd)\(profileModel.isEmpty ? "" : " · \(profileModel)")")
                        .font(DS.mono(9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let t = activeCaseTitle {
                    Button {
                        if let id = activeCaseID { presentedCase = CaseRef(id: id) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .bold))
                            Text("Working · \(t)").lineLimit(1)
                        }
                        .font(DS.mono(9, .semibold))
                        .foregroundStyle(DS.Ink.mintDeep)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(DS.Ink.mint.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(DS.Canvas.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
            .padding(.horizontal, 12)
        }
    }

    private func loadProfileBand() async {
        let name = current.isEmpty ? sessionName : current
        if let profiles = try? await APIClient.shared.fetchAgentProfiles() {
            let p = profiles.first { name == $0.name || name.hasPrefix($0.name + "-") }
            await MainActor.run {
                profileCwd = p?.cwd ?? ""
                profileModel = p?.model ?? ""
            }
        }
        if let wfs = try? await APIClient.shared.fetchWorkflows() {
            let w = wfs.first {
                ["running", "waiting_human"].contains($0.status)
                    && ($0.meta?["assigned_session"]?.stringValue == name || $0.session == name)
            }
            await MainActor.run {
                activeCaseTitle = w.map { String($0.title.prefix(12)) }
                activeCaseID = w?.id
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(ANSI.clean(terminalVM.content))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(DS.Canvas.phosphor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .textSelection(.enabled)
                    .id("content")
            }
            .background(DS.Canvas.terminal)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
            .glassBorder(DS.R.md)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .safeAreaInset(edge: .top) { profileBand }
            .safeAreaInset(edge: .bottom) { inputBar }
            .onChange(of: terminalVM.content) { _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("content", anchor: .bottom)
                }
            }
            // Mid-screen right swipe → session drawer. Edge swipes stay with
            // the system back gesture; this only fires from further in.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .global)
                    .onEnded { v in
                        if v.translation.width > 70, abs(v.translation.height) < 60,
                           v.startLocation.x > 44 {
                            showDrawer = true
                        }
                    }
            )
        }
        .navigationTitle(current.isEmpty ? sessionName : current)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let onClose {
                    Button(action: onClose) {
                        Label("Close", systemImage: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close terminal")
                }
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(terminalVM.isConnected ? DS.Ink.mint : DS.Ink.zinc)
                        .frame(width: 6, height: 6)
                        .breathing(terminalVM.isConnected)
                    Text(current.isEmpty ? sessionName : current)
                        .font(DS.mono(11, .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        openDrawer()
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Sessions")
                    Button {
                        Task { await terminalVM.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .rotationEffect(terminalVM.isRefreshing ? .degrees(360) : .zero)
                            .animation(
                                terminalVM.isRefreshing
                                    ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                    : .default,
                                value: terminalVM.isRefreshing
                            )
                    }
                    .disabled(terminalVM.isRefreshing)
                    .accessibilityLabel("Refresh")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { inputFocused = false }
            }
        }
        .onAppear {
            if current.isEmpty { current = sessionName }
            terminalVM.connect(sessionName: current)
            Task { await loadProfileBand() }
        }
        .sheet(item: $presentedCase) { ref in
            WorkflowDetailSheet(vm: caseVM, workflowID: ref.id)
                .presentationDetents([.large])
                .onAppear { Task { await caseVM.select(ref.id) } }
        }
        .onDisappear { terminalVM.disconnect() }
        .overlay { drawer }
    }

    // ── Swipe-out session drawer ──

    private func openDrawer() {
        inputFocused = false
        showDrawer = true
        Task {
            drawerSessions = (try? await APIClient.shared.fetchSessions()) ?? drawerSessions
        }
    }

    private func switchSession(_ s: Session) {
        guard s.name != current else { showDrawer = false; return }
        current = s.name
        terminalVM.connect(sessionName: s.name)
        showDrawer = false
    }

    private var drawer: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if showDrawer {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(DS.snappy) { showDrawer = false } }
                        .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Session")
                            .font(DS.display(15, .semibold))
                        Text("\(drawerSessions.count)")
                            .font(DS.mono(12, .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 10)

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(drawerSessions) { s in
                                DrawerRow(
                                    session: s,
                                    isCurrent: s.name == (current.isEmpty ? sessionName : current)
                                ) { switchSession(s) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 16)
                    }
                }
                .frame(width: 290)
                .frame(maxHeight: .infinity)
                .background(DS.Canvas.app.ignoresSafeArea())
                .offset(x: showDrawer ? 0 : -300)
                .animation(DS.snappy, value: showDrawer)
            }
            .ignoresSafeArea()
            .allowsHitTesting(showDrawer)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("send to \(current.isEmpty ? sessionName : current)", text: $inputText)
                .font(DS.mono(13, .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .foregroundStyle(.primary)
                .background(DS.Canvas.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous))
                .glassBorder(DS.R.md)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { sendInput() }

            Button(action: sendInput) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(inputText.isEmpty ? DS.Ink.zinc : DS.Ink.mint)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            }
            .disabled(inputText.isEmpty)
            .animation(DS.snappy, value: inputText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private func sendInput() {
        let text = inputText
        guard !text.isEmpty else { return }
        inputText = ""
        // Send goes via HTTP POST /api/sessions/<name>/send, which calls
        // `tmux send-keys` on the server. send-keys handles raw-mode CR
        // semantics internally, so we send the text as-is.
        terminalVM.send(text: text)
    }
}

private struct DrawerRow: View {
    let session: Session
    let isCurrent: Bool
    let onTap: () -> Void

    private var dotColor: Color {
        if session.working { return DS.Ink.amber }
        return session.active ? DS.Ink.done : DS.Ink.zinc
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .breathing(session.working)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(DS.mono(13, isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? DS.Ink.mint : .primary)
                        .lineLimit(1)
                    Text(session.agent.isEmpty ? "shell" : session.agent)
                        .font(DS.micro(9, .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(session.agent.isEmpty ? Color.secondary : DS.Ink.done)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Ink.mint)
                } else if session.unread > 0 {
                    UnreadBadge(count: session.unread)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isCurrent ? DS.Ink.mint.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// Red count badge for finished-task notifications the user hasn't viewed.
// Shared by the terminal drawer and the Agents tab rows.
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(DS.micro(9, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(DS.Ink.rose)
            .clipShape(Capsule())
    }
}

// MARK: - Press-down button style

struct PressDown: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(DS.snappy, value: configuration.isPressed)
    }
}
