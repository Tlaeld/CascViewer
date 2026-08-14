import SwiftUI
import SceneKit
import CoreVideo

struct ModelViewerWindow: View {
    let fileName: String
    let modelScene: ModelScene
    let built: BuiltModelScene
    @StateObject private var viewModel = ModelViewerViewModel()
    @State private var showRenderSettings = false

    /// 当前设置下实际可见的网格数(材质类型过滤仅对 M3 生效,与打开处逻辑一致)
    private var visibleMeshCount: Int {
        guard modelScene.format == .m3 else { return modelScene.meshes.count }
        let hidden = AppSettings.shared.hiddenM3MaterialTypes
        return modelScene.meshes.filter { !hidden.contains($0.materialType) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fileName).font(.headline)
                Spacer()
                if !viewModel.player.animationNames.isEmpty {
                    Picker(L("animation_label"), selection: $viewModel.selectedAnimation) {
                        ForEach(Array(viewModel.player.animationNames.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index)
                        }
                    }
                    .frame(maxWidth: 220)
                    Button(viewModel.isPlaying ? "⏸" : "▶") {
                        viewModel.togglePlayback()
                    }
                } else {
                    Text(L("no_animations")).foregroundColor(.secondary)
                }
                if modelScene.format == .m3 {
                    Button { showRenderSettings.toggle() } label: {
                        Image(systemName: "gearshape")
                    }
                    .popover(isPresented: $showRenderSettings, arrowEdge: .bottom) {
                        ModelRenderSettingsPopover(
                            modelScene: modelScene,
                            initialHidden: AppSettings.shared.hiddenM3MaterialTypes
                        ) { hidden in
                            AppSettings.shared.hiddenM3MaterialTypes = hidden
                            viewModel.rebuild(with: ModelSceneBuilder.build(
                                modelScene, hiddenMaterialTypes: hidden))
                        }
                    }
                }
            }
            .padding()

            Divider()

            ZStack {
                ModelViewerView(scene: viewModel.scnScene, pointOfView: viewModel.cameraNode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if visibleMeshCount == 0 {
                    // 空态提示:区分"文件本身无网格"(m3a 动画库)与"全部被渲染设置隐藏"
                    Text(modelScene.meshes.isEmpty ? L("model_no_mesh") : L("model_all_hidden"))
                        .foregroundColor(.secondary)
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(8)
                }
            }

            Divider()

            HStack {
                Text("\(modelScene.meshes.count) meshes · \(modelScene.bones.count) bones · \(modelScene.animations.count) anims")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            viewModel.setup(scene: modelScene, built: built)
        }
        .onDisappear {
            viewModel.stopAnimation()
        }
    }
}

private let modelDisplayLinkCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context -> CVReturn in
    guard let context = context else { return kCVReturnError }
    let viewModel = Unmanaged<ModelViewerViewModel>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        viewModel.tick()
    }
    return kCVReturnSuccess
}

@MainActor
final class ModelViewerViewModel: ObservableObject {
    @Published var scnScene = SCNScene()
    /// 取景相机(须显式赋给 SCNView.pointOfView,否则 SCNView 用自带默认相机角度)
    @Published var cameraNode: SCNNode?
    @Published var isPlaying = false
    @Published var selectedAnimation = 0 {
        didSet {
            player.selectAnimation(index: selectedAnimation)
            currentTimeMs = 0
            startTime = 0  // 触发 tick() 里的重锚定(if startTime == 0),否则非循环动画卡最后一帧
        }
    }

    private(set) var player = ModelAnimationPlayer(scene: ModelScene(
        name: "", format: .mdx, meshes: [], materials: [], bones: [], animations: [],
        boundsMin: .zero, boundsMax: .zero),
        built: BuiltModelScene(rootNode: SCNNode(), boneNodes: []))

    private var modelScene: ModelScene?
    private var displayLink: CVDisplayLink?
    private var displayLinkContext: UnsafeMutableRawPointer?
    private var startTime: CFTimeInterval = 0
    private var currentTimeMs: Float = 0

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            CVDisplayLinkSetOutputCallback(displayLink, nil, nil)
        }
        if let context = displayLinkContext {
            Unmanaged<ModelViewerViewModel>.fromOpaque(context).release()
        }
    }

    func setup(scene: ModelScene, built: BuiltModelScene) {
        modelScene = scene
        player = ModelAnimationPlayer(scene: scene, built: built)
        scnScene.rootNode.addChildNode(built.rootNode)
        frameCamera(to: scene)
        if !scene.animations.isEmpty {
            player.selectAnimation(index: 0)
            togglePlayback()
        }
    }

    /// 相机取景:按包围盒对角线把默认相机拉远(中心经 Z-up→Y-up 旋转校正)。
    private func frameCamera(to scene: ModelScene) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let size = scene.boundsMax - scene.boundsMin
        let center = ModelSceneBuilder.visualCenter(of: scene)
        let radius = max(simd_length(size) / 2, 0.001)
        // M3 模型正面朝模型空间 -Y;经 Z-up→Y-up 旋转后正面朝 +Z,相机放 +Z 一侧看正面
        cameraNode.position = SCNVector3(center.x, center.y + radius * 0.4,
                                         center.z + radius * 2.5)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        cameraNode.camera?.automaticallyAdjustsZRange = true
        scnScene.rootNode.addChildNode(cameraNode)
        self.cameraNode = cameraNode
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying { startAnimation() } else { stopAnimation() }
    }

    /// 材质可见性变化后,用同一 ModelScene 重建的场景替换当前场景。
    /// 保留动画索引与播放/暂停状态(进度重置为 0);相机节点复用,保留用户视角。
    func rebuild(with built: BuiltModelScene) {
        guard let scene = modelScene else { return }
        let wasPlaying = isPlaying
        if wasPlaying { stopAnimation() }
        let camera = cameraNode
        camera?.removeFromParentNode()
        let newScene = SCNScene()
        newScene.rootNode.addChildNode(built.rootNode)
        if let camera { newScene.rootNode.addChildNode(camera) }
        scnScene = newScene
        player = ModelAnimationPlayer(scene: scene, built: built)
        if !scene.animations.isEmpty {
            player.selectAnimation(index: selectedAnimation)
            if wasPlaying { startAnimation() }
        }
    }

    func tick() {
        let now = CACurrentMediaTime()
        if startTime == 0 { startTime = now }
        currentTimeMs = Float((now - startTime) * 1000)
        player.update(timeMs: currentTimeMs)
    }

    private func startAnimation() {
        stopAnimation()
        startTime = 0
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let displayLink = link else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        displayLinkContext = context
        CVDisplayLinkSetOutputCallback(displayLink, modelDisplayLinkCallback, context)
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }

    func stopAnimation() {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            CVDisplayLinkSetOutputCallback(displayLink, nil, nil)
        }
        if let context = displayLinkContext {
            Unmanaged<ModelViewerViewModel>.fromOpaque(context).release()
            displayLinkContext = nil
        }
        displayLink = nil
    }
}

// MARK: - Window opener(镜像 ImageViewerWindowController 模式)

@MainActor
final class ModelViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [ModelViewerWindowController] = []
    private static let lock = NSLock()

    init(fileName: String, modelScene: ModelScene, built: BuiltModelScene) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileName
        window.setContentSize(NSSize(width: 900, height: 640))
        window.setFrameAutosaveName("CascViewerModelWindow")
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: ModelViewerWindow(fileName: fileName, modelScene: modelScene, built: built))
        Self.lock.lock()
        Self.controllers.append(self)
        Self.lock.unlock()
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.lock.lock()
            Self.controllers.removeAll { $0 === self }
            Self.lock.unlock()
        }
    }
}

@MainActor
func openModelViewerWindow(fileName: String, modelScene: ModelScene, built: BuiltModelScene) {
    _ = ModelViewerWindowController(fileName: fileName, modelScene: modelScene, built: built)
}

/// 渲染设置弹层:12 种 M3 材质类型的可见性开关(全局持久,存 AppSettings)。
private struct ModelRenderSettingsPopover: View {
    let modelScene: ModelScene
    let onChange: (Set<Int>) -> Void
    @State private var hidden: Set<Int>

    init(modelScene: ModelScene, initialHidden: Set<Int>,
         onChange: @escaping (Set<Int>) -> Void) {
        self.modelScene = modelScene
        self.onChange = onChange
        _hidden = State(initialValue: initialHidden)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("render_settings")).font(.headline)
            ForEach(M3MaterialKind.allCases) { kind in
                let count = modelScene.meshes.filter { $0.materialType == kind.rawValue }.count
                Toggle(isOn: binding(for: kind)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(kind.displayName) · \(count)")
                        Text(L(kind.descriptionKey))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func binding(for kind: M3MaterialKind) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(kind.rawValue) },
            set: { visible in
                if visible { hidden.remove(kind.rawValue) } else { hidden.insert(kind.rawValue) }
                onChange(hidden)
            }
        )
    }
}
