import SwiftUI
import SceneKit

/// 自定义滚轮缩放:默认要按住 Option 才能缩放,反直觉。
/// 鼠标滚轮(非精密滚动)= 直接缩放,按住 Command 加速;
/// 触控板双指滚动(精密滚动)维持默认手势不变。
final class ModelSceneView: SCNView {
    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        let speed: Float = event.modifierFlags.contains(.command) ? 6 : 2
        defaultCameraController.dolly(toTarget: Float(event.scrollingDeltaY) * speed)
    }
}

/// SCNView 的 SwiftUI 包装;场景由 viewModel 构建好后整体替换。
struct ModelViewerView: NSViewRepresentable {
    let scene: SCNScene
    /// 取景相机;必须显式设置,否则 allowsCameraControl 下 SCNView 用自带默认相机角度
    let pointOfView: SCNNode?
    /// 轨道旋转中心(模型取景中心);不设则默认绕世界原点旋转,模型偏位时会甩视角
    let cameraTarget: SCNVector3

    func makeNSView(context: Context) -> SCNView {
        let view = ModelSceneView()
        view.scene = scene
        view.pointOfView = pointOfView
        // macOS 对应 API 是 allowsCameraControl(非 iOS 的 allowsCameraInteraction),
        // 默认 NO,需显式开启才能用鼠标旋转/缩放相机
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false  // 光照由 builder 提供
        view.backgroundColor = NSColor(white: 0.12, alpha: 1)
        view.defaultCameraController.target = cameraTarget
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = scene
        if let pov = pointOfView, nsView.pointOfView !== pov {
            nsView.pointOfView = pov
        }
        nsView.defaultCameraController.target = cameraTarget
    }
}
