import SwiftUI
import SceneKit

/// SCNView 的 SwiftUI 包装;场景由 viewModel 构建好后整体替换。
struct ModelViewerView: NSViewRepresentable {
    let scene: SCNScene
    /// 取景相机;必须显式设置,否则 allowsCameraControl 下 SCNView 用自带默认相机角度
    let pointOfView: SCNNode?

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = pointOfView
        // macOS 对应 API 是 allowsCameraControl(非 iOS 的 allowsCameraInteraction),
        // 默认 NO,需显式开启才能用鼠标旋转/缩放相机
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false  // 光照由 builder 提供
        view.backgroundColor = NSColor(white: 0.12, alpha: 1)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = scene
        if let pov = pointOfView, nsView.pointOfView !== pov {
            nsView.pointOfView = pov
        }
    }
}
