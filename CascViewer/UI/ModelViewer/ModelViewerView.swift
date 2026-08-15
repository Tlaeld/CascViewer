import SwiftUI
import SceneKit

/// SCNView 的 SwiftUI 包装;场景由 viewModel 构建好后整体替换。
struct ModelViewerView: NSViewRepresentable {
    let scene: SCNScene
    /// 取景相机;必须显式设置,否则 allowsCameraControl 下 SCNView 用自带默认相机角度
    let pointOfView: SCNNode?
    /// 轨道旋转中心(模型取景中心);不设则默认绕世界原点旋转,模型偏位时会甩视角
    let cameraTarget: SCNVector3
    /// 动画驱动挂在 SceneKit 渲染循环上(原先 CVDisplayLink 每帧向主 actor 派
    /// 一个 Task,菜单跟踪期间会抢占事件处理,导致 Picker 下拉卡死成半透明)
    weak var viewModel: ModelViewerViewModel?

    func makeCoordinator() -> RenderCoordinator {
        RenderCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = pointOfView
        // macOS 对应 API 是 allowsCameraControl(非 iOS 的 allowsCameraInteraction),
        // 默认 NO,需显式开启才能用鼠标旋转/缩放相机
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false  // 光照由 builder 提供
        view.backgroundColor = NSColor(white: 0.12, alpha: 1)
        view.defaultCameraController.target = cameraTarget
        view.delegate = context.coordinator
        view.isPlaying = true  // 持续渲染,每帧回调 renderer(_:updateAtTime:)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = scene
        if let pov = pointOfView, nsView.pointOfView !== pov {
            nsView.pointOfView = pov
        }
        nsView.defaultCameraController.target = cameraTarget
        context.coordinator.viewModel = viewModel
    }

    final class RenderCoordinator: NSObject, SCNSceneRendererDelegate {
        weak var viewModel: ModelViewerViewModel?
        init(viewModel: ModelViewerViewModel?) { self.viewModel = viewModel }

        /// SCNView 的渲染回调在主线程触发;万一不在主线程才回落到主队列
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { viewModel?.tick() }
            } else {
                DispatchQueue.main.async { [weak viewModel] in
                    viewModel?.tick()
                }
            }
        }
    }
}
