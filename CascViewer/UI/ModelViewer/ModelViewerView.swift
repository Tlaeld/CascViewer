import SwiftUI
import SceneKit

/// SCNView 的 SwiftUI 包装;场景由 viewModel 构建好后整体替换。
struct ModelViewerView: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        // macOS 对应 API 是 allowsCameraControl(非 iOS 的 allowsCameraInteraction),
        // 默认 NO,需显式开启才能用鼠标旋转/缩放相机
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false  // 光照由 builder 提供
        view.backgroundColor = NSColor(white: 0.12, alpha: 1)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = scene
    }
}
