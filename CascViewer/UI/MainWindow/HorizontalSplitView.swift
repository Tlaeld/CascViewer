import SwiftUI
import AppKit

/// 横向二分栏(左:固定宽度、可拖动调整的侧栏,可整体折叠;右:弹性内容)。
///
/// 为什么不用系统 NavigationSplitView:实测在 macOS 26/27 上,它自动装进标题栏的
/// 侧栏 toggle 按钮折叠后会跳到标题栏右侧,且 .toolbar(removing: .sidebarToggle)
/// 无法移除;折叠/展开过渡会把文件列表的渲染卡死在半透明(视图/动画均不恢复);
/// 绑定 columnVisibility 后,从窗口左缘拖拽展开又会在松手时弹回折叠态。
/// 这里回到显式宽度 + 折叠标志 + 拖拽条的确定性方案:宽度只在拖动结束时写一次
/// @AppStorage;折叠/展开即时生效,不经过任何系统过渡动画。
struct HorizontalSplitView<Side: View, Detail: View>: View {
    /// @AppStorage 键名(持久化侧栏宽度)
    var storageKey: String
    var defaultWidth: CGFloat = 240
    var minWidth: CGFloat = 180
    var maxWidth: CGFloat = 400
    @Binding var collapsed: Bool
    @ViewBuilder var side: () -> Side
    @ViewBuilder var detail: () -> Detail

    @AppStorage private var width: Double
    @State private var dragWidth: CGFloat? = nil
    @State private var dragStartWidth: CGFloat = 0

    init(storageKey: String,
         defaultWidth: CGFloat = 240,
         minWidth: CGFloat = 180,
         maxWidth: CGFloat = 400,
         collapsed: Binding<Bool>,
         @ViewBuilder side: @escaping () -> Side,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.storageKey = storageKey
        self.defaultWidth = defaultWidth
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self._collapsed = collapsed
        self.side = side
        self.detail = detail
        _width = AppStorage(wrappedValue: defaultWidth, storageKey)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !collapsed {
                let current = min(max(dragWidth ?? CGFloat(width), minWidth), maxWidth)
                side()
                    .frame(width: current)
                    .frame(maxHeight: .infinity)
                    .background(SidebarVisualEffectBackground())
                    .clipped()
                divider(current: current)
            }
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func divider(current: CGFloat) -> some View {
        Divider()
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if dragWidth == nil { dragStartWidth = current }
                                dragWidth = min(max(dragStartWidth + value.translation.width, minWidth), maxWidth)
                            }
                            .onEnded { _ in
                                // 只在拖动结束时持久化一次,避免逐帧写 UserDefaults
                                if let w = dragWidth { width = Double(w) }
                                dragWidth = nil
                            }
                    )
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
            )
    }
}

/// 侧栏毛玻璃背景:复刻系统 NavigationSplitView sidebar 的 vibrancy 观感。
/// 用 NSVisualEffectView 而不是回到系统组件——系统组件的折叠过渡在 macOS 27 上
/// 会把 vibrant 文字渲染卡死在灰态(见上方注释),材质本身没有任何问题。
/// 材质上再叠一层半透明窗口底色:纯 .sidebar 材质会把背后窗口的颜色透得很明显,
/// 叠一层 dimming 后只保留轻微质感,文字可读性接近实色背景。
private struct SidebarVisualEffectBackground: NSViewRepresentable {
    /// 遮盖强度:0 = 纯毛玻璃(透出度最高),1 = 接近实色
    var dimming: CGFloat = 0.55

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState

        let veil = NSView()
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(dimming).cgColor
        veil.autoresizingMask = [.width, .height]
        veil.frame = view.bounds
        view.addSubview(veil)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // 深/浅主题切换时刷新遮盖层颜色(cgColor 是快照,不会跟随动态色)
        nsView.subviews.first?.layer?.backgroundColor =
            NSColor.windowBackgroundColor.withAlphaComponent(dimming).cgColor
    }
}
