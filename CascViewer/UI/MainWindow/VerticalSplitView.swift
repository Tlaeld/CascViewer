import SwiftUI
import AppKit

/// 竖向二分栏(上:弹性内容;下:固定高度、可拖动调整)。
///
/// 为什么不用系统 VSplitView/NSSplitView:实测在 macOS 26 上 VSplitView 会把多余空间
/// 全分给最后一个子视图(上方列表被压到最小高度);手桥 NSSplitView 则因子视图被
/// 布局约束钉死,setPosition/拖动都会弹回。这里回到显式高度 + 拖拽条的确定性方案:
/// 底部高度只在拖动结束时写一次 @AppStorage,不存在"测量-持久化"反馈循环。
struct VerticalSplitView<Top: View, Bottom: View>: View {
    /// @AppStorage 键名(持久化底部面板高度)
    var storageKey: String
    var bottomDefaultHeight: CGFloat = 220
    var topMin: CGFloat = 240
    var bottomMin: CGFloat = 140
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    @AppStorage private var bottomHeight: Double
    @State private var dragHeight: CGFloat? = nil
    @State private var dragStartHeight: CGFloat = 0

    init(storageKey: String,
         bottomDefaultHeight: CGFloat = 220,
         topMin: CGFloat = 240,
         bottomMin: CGFloat = 140,
         @ViewBuilder top: @escaping () -> Top,
         @ViewBuilder bottom: @escaping () -> Bottom) {
        self.storageKey = storageKey
        self.bottomDefaultHeight = bottomDefaultHeight
        self.topMin = topMin
        self.bottomMin = bottomMin
        self.top = top
        self.bottom = bottom
        _bottomHeight = AppStorage(wrappedValue: bottomDefaultHeight, storageKey)
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let maxBottom = max(bottomMin, total - topMin - 1)
            let current = min(max(dragHeight ?? CGFloat(bottomHeight), bottomMin), maxBottom)
            VStack(spacing: 0) {
                top()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                divider(current: current, maxBottom: maxBottom)
                bottom()
                    .frame(maxWidth: .infinity)
                    .frame(height: current, alignment: .top)
                    .clipped()
            }
        }
    }

    private func divider(current: CGFloat, maxBottom: CGFloat) -> some View {
        Divider()
            .frame(height: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if dragHeight == nil { dragStartHeight = current }
                                let newHeight = dragStartHeight - value.translation.height
                                dragHeight = min(max(newHeight, bottomMin), maxBottom)
                            }
                            .onEnded { _ in
                                // 只在拖动结束时持久化一次,避免窗口缩放把瞬时尺寸写进配置
                                if let h = dragHeight { bottomHeight = Double(h) }
                                dragHeight = nil
                            }
                    )
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
                    }
            )
    }
}
