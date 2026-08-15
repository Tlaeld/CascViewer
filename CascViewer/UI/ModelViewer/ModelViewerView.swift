import SwiftUI
import SceneKit

/// 自定义相机交互(取景相机直接挂在场景根节点下,local 坐标即 world 坐标):
/// - 滚轮 = 缩放。SceneKit 默认对精密滚动设备要按住 Option 才能缩放,反直觉;
///   且 dollyToTarget 按世界单位做加法,距离远近手感完全不同。这里按"到目标的距离"
///   做乘法缩放,任意距离手感一致,不设距离限制;普通滚轮忽略系统滚动加速度、
///   每格固定一档,高分辨率滚轮钳制尖峰;按住 Command 加速 3 倍。
/// - 鼠标中键/右键拖动 = 平移,内容跟随鼠标;相机与旋转目标一起移动,
///   幅度按当前距离换算,远近手感一致。
/// - 触控板双指滚动带 phase/momentumPhase,维持 SceneKit 默认手势不变。
final class ModelSceneView: SCNView {
    private var lastPanLocation = NSPoint.zero

    override func scrollWheel(with event: NSEvent) {
        let isTouchScroll = event.phase != [] || event.momentumPhase != []
        guard !isTouchScroll else {
            super.scrollWheel(with: event)
            return
        }

        let notches: Float
        if event.hasPreciseScrollingDeltas {
            notches = max(-2.5, min(2.5, Float(event.scrollingDeltaY))) * 0.12
        } else {
            let delta = event.scrollingDeltaY
            notches = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        }
        guard notches != 0, let pov = pointOfView else { return }

        defaultCameraController.stopInertia()
        let factor = powf(0.9, notches * (event.modifierFlags.contains(.command) ? 3 : 1))
        let target = simd_float3(defaultCameraController.target)
        pov.simdPosition = target + (pov.simdPosition - target) * factor
    }

    override func rightMouseDown(with event: NSEvent) {
        lastPanLocation = convert(event.locationInWindow, from: nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        lastPanLocation = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        pan(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        pan(with: event)
    }

    private func pan(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let dx = Float(location.x - lastPanLocation.x)
        let dy = Float(location.y - lastPanLocation.y)
        lastPanLocation = location

        guard let pov = pointOfView, bounds.height > 0 else { return }
        defaultCameraController.stopInertia()

        let target = simd_float3(defaultCameraController.target)
        let distance = simd_distance(pov.simdPosition, target)
        guard distance > 1e-5 else { return }

        // 视口高度对应的世界尺寸 = 2 * distance * tan(fov/2);
        // fieldOfView 默认按纵向量(projectionDirection 默认 vertical)
        let fov = Float((pov.camera?.fieldOfView ?? 60) * .pi / 180)
        let worldPerPoint = 2 * distance * tanf(fov / 2) / Float(bounds.height)

        // 相机世界朝向的右/上基向量(归一化,防世界变换带缩放)
        let m = pov.simdWorldTransform
        let right = simd_normalize(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))

        // 内容跟随鼠标:相机与目标反向等量平移
        let offset = (-right * dx - up * dy) * worldPerPoint
        pov.simdPosition += offset
        let t = target + offset
        defaultCameraController.target = SCNVector3(x: SCNFloat(t.x), y: SCNFloat(t.y), z: SCNFloat(t.z))
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
