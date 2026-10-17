import SwiftUI

// MARK: - Design Tokens
// 橘粒品牌 tokens（Penpot 板 00 · makro-iphone 设计系统）：
// 暖白纸感底、#D97C26 主色只做点缀；状态语义=文字主编码+色彩冗余，
// 完成=苔绿、进行中=主橘（呼吸）、待审=琥珀、失败/已驳回=降饱和红。
// 字阶（板 00）：大标题 24/700 · 卡标题 16/600 · 正文 14/400 · 标签 11/500
// MONO；圆角：间距 8 基准 · 卡片 14 · 按钮 10 · pill 全圆。
// mint/mintDeep 保留旧名（全工程引用），语义已变为主橘/深橘。
enum DS {
    enum Ink {
        static let mint = Color(red: 0.851, green: 0.486, blue: 0.149)   // 主橘 #D97C26
        static let mintDeep = Color(red: 0.722, green: 0.408, blue: 0.102) // 深橘 #B8681A
        static let amber = Color(red: 0.753, green: 0.541, blue: 0.243)  // 待审琥珀 #C08A3E
        static let rose = Color(red: 0.761, green: 0.357, blue: 0.306)   // 失败 #C25B4E
        static let zinc = Color(red: 0.557, green: 0.549, blue: 0.518)   // 已取消 #8E8C84
        static let slate = Color(red: 0.42, green: 0.45, blue: 0.5)      // 排队中 冷灰蓝(与取消暖灰区分)
        static let done = Color(red: 0.431, green: 0.545, blue: 0.369)   // 完成 苔绿 #6E8B5E
    }

    enum Canvas {
        // 暖白纸感（禁纯白页面底/纯黑）
        static let app = Color(red: 0.980, green: 0.980, blue: 0.973)    // #FAFAF8
        static let card = Color(red: 1.0, green: 1.0, blue: 1.0)
        static let inset = Color(red: 0.949, green: 0.945, blue: 0.925)  // #F2F1EC
        static let terminal = Color(red: 0.141, green: 0.137, blue: 0.122) // #24231F 暖黑
        static let phosphor = Color(red: 0.910, green: 0.902, blue: 0.878) // #E8E6E0 暖白字
    }

    static func display(_ size: CGFloat = 24, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// 卡标题档（板 00 字阶：16/600）——列表行/卡片标题的 canonical rung。
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
        // 板 00：间距 8 基准 · 卡片圆角 14 · 按钮 10 · pill 全圆。
        static let sm: CGFloat = 8   // 小元素/内嵌块（= 间距基准）
        static let md: CGFloat = 14  // 卡片
        static let btn: CGFloat = 10 // 按钮
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

// MARK: - Pull-to-refresh（ScrollView 可靠版）
// .refreshable 挂 ScrollView 触发不可靠（iOS 16 起官方支持但实测丢触发——
// 三 tab 曾表现为「有的能刷有的不能」，List 的 Agents 能、ScrollView 的
// Flow/Artifacts 不能）。onScrollGeometryChange（iOS 18+）检测过拉沿，
// 沿触发 + isRefreshing 防重入 + 250ms 尾垫防闪。
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
    /// 板 02 手势统一：下拉即刷（三 tab 同一手势，刷新按钮因此退役）。
    func pullToRefresh(_ action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(action: action))
    }
}

