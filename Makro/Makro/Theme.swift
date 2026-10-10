import SwiftUI

// MARK: - Design Tokens
// Juli-brand tokens (Penpot board 00 · the makro-iphone design system):
// warm paper-white base, #D97C26 primary used only as an accent; status
// semantics = text as the primary code + color as redundancy: done = moss
// green, running = primary orange (breathing), awaiting review = amber,
// failed/rejected = desaturated red.
// Type scale (board 00): display 24/700 · card title 16/600 · body 14/400 ·
// label 11/500 MONO; corner radii: spacing base 8 · card 14 · button 10 ·
// pill fully round.
// mint/mintDeep keep their old names (referenced project-wide); their
// semantics are now primary orange / deep orange.
enum DS {
    enum Ink {
        static let mint = Color(red: 0.851, green: 0.486, blue: 0.149)   // primary orange #D97C26
        static let mintDeep = Color(red: 0.722, green: 0.408, blue: 0.102) // deep orange #B8681A
        static let amber = Color(red: 0.753, green: 0.541, blue: 0.243)  // awaiting-review amber #C08A3E
        static let rose = Color(red: 0.761, green: 0.357, blue: 0.306)   // failed #C25B4E
        static let zinc = Color(red: 0.557, green: 0.549, blue: 0.518)   // cancelled #8E8C84
        static let slate = Color(red: 0.42, green: 0.45, blue: 0.5)      // queued, cool gray-blue (distinct from cancelled's warm gray)
        static let done = Color(red: 0.431, green: 0.545, blue: 0.369)   // done, moss green #6E8B5E
    }

    enum Canvas {
        // Warm paper-white feel (no pure-white page background / pure black)
        static let app = Color(red: 0.980, green: 0.980, blue: 0.973)    // #FAFAF8
        static let card = Color(red: 1.0, green: 1.0, blue: 1.0)
        static let inset = Color(red: 0.949, green: 0.945, blue: 0.925)  // #F2F1EC
        static let terminal = Color(red: 0.141, green: 0.137, blue: 0.122) // #24231F warm black
        static let phosphor = Color(red: 0.910, green: 0.902, blue: 0.878) // #E8E6E0 warm-white text
    }

    static func display(_ size: CGFloat = 24, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Card-title rung (board 00 type scale: 16/600) — the canonical rung for list-row/card titles.
    static func cardTitle(_ size: CGFloat = 16, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func text(_ size: CGFloat = 14, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func micro(_ size: CGFloat = 10, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.76)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.85)

    enum R {
        // Board 00: spacing base 8 · card corner radius 14 · button 10 · pill fully round.
        static let sm: CGFloat = 8   // small elements / inset blocks (= spacing base)
        static let md: CGFloat = 14  // cards
        static let btn: CGFloat = 10 // buttons
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
    }
}

// MARK: - Breathing (perpetual micro-interaction)
private struct Breathing: ViewModifier {
    @State private var alive = false
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active && alive ? 1.15 : 0.88)
            .opacity(active && alive ? 1.0 : 0.5)
            .animation(active ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: alive)
            .onAppear { alive = true }
    }
}

extension View {
    func breathing(_ active: Bool = true) -> some View { modifier(Breathing(active: active)) }

    func glassBorder(_ radius: CGFloat = DS.R.lg) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    func innerHighlight(_ radius: CGFloat = DS.R.lg) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .blur(radius: 0.5)
                .mask(RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: 0.5))
        )
    }

    /// Sweeps a diagonal highlight across placeholder shapes (loading skeletons).
    /// Used on redacted/inset blocks to signal "loading" without a spinner.
    func shimmering() -> some View { modifier(Shimmer()) }
}

// MARK: - Shimmer (skeleton highlight sweep)

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color.white.opacity(0.55), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width * 1.5)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                phase = -1
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Status pill
struct StatusPill: View {
    enum Mode { case active, idle, thinking, error, connecting
        var tint: Color {
            switch self {
            case .active: return DS.Ink.mint
            case .idle: return DS.Ink.zinc
            case .thinking: return DS.Ink.amber
            case .error: return DS.Ink.rose
            case .connecting: return DS.Ink.amber
            }
        }
        var label: String {
            switch self {
            case .active: return "live"
            case .idle: return "idle"
            case .thinking: return "thinking"
            case .error: return "error"
            case .connecting: return "linking"
            }
        }
    }
    let mode: Mode
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(mode.tint)
                .frame(width: 6, height: 6)
                .breathing(mode == .active || mode == .thinking || mode == .connecting)
            Text(mode.label)
                .font(DS.micro(compact ? 9 : 10))
                .textCase(.uppercase)
                .foregroundStyle(mode.tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(mode.tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Pull-to-refresh (reliable ScrollView version)
// .refreshable on a ScrollView fires unreliably (officially supported since
// iOS 16 but empirically drops triggers — the three tabs once showed "some
// refresh, some don't": the List-based Agents did, the ScrollView-based
// Flow/Artifacts did not). onScrollGeometryChange (iOS 18+) detects the
// overscroll edge; edge trigger + isRefreshing re-entrancy guard + a 250ms
// tail pad against flashing.
struct PullToRefresh: ViewModifier {
    let action: () async -> Void
    @State private var refreshing = false
    private let threshold: CGFloat = -64

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if refreshing {
                    ProgressView()
                        .tint(DS.Ink.mint)
                        .controlSize(.large)
                        .padding(.top, 8)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, value in
                if !refreshing && value < threshold {
                    refreshing = true
                    Task {
                        await action()
                        try? await Task.sleep(for: .milliseconds(250))
                        refreshing = false
                    }
                }
            }
    }
}

extension View {
    /// Board 02 gesture unification: pull down to refresh (the same gesture on all three tabs; the refresh button was retired for it).
    func pullToRefresh(_ action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(action: action))
    }
}

