import SwiftUI
import SceneKit
import CoreVideo

struct ModelViewerWindow: View {
    let fileName: String
    let modelScene: ModelScene
    let built: BuiltModelScene
    @StateObject private var viewModel = ModelViewerViewModel()

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
            }
            .padding()

            Divider()

            ModelViewerView(scene: viewModel.scnScene)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
    @Published var isPlaying = false
    @Published var selectedAnimation = 0 {
        didSet { player.selectAnimation(index: selectedAnimation); currentTimeMs = 0 }
    }

    private(set) var player = ModelAnimationPlayer(scene: ModelScene(
        name: "", format: .mdx, meshes: [], materials: [], bones: [], animations: [],
        boundsMin: .zero, boundsMax: .zero),
        built: BuiltModelScene(rootNode: SCNNode(), boneNodes: []))

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
        player = ModelAnimationPlayer(scene: scene, built: built)
        scnScene.rootNode.addChildNode(built.rootNode)
        frameCamera(to: scene)
        if !scene.animations.isEmpty {
            player.selectAnimation(index: 0)
            togglePlayback()
        }
    }

    /// 相机取景:按包围盒对角线把默认相机拉远。
    private func frameCamera(to scene: ModelScene) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let size = scene.boundsMax - scene.boundsMin
        let center = (scene.boundsMax + scene.boundsMin) / 2
        let radius = max(simd_length(size) / 2, 0.001)
        cameraNode.position = SCNVector3(center.x, center.y, center.z + radius * 3)
        cameraNode.camera?.automaticallyAdjustsZRange = true
        // SCNScene 无 pointOfView(属 SCNSceneRenderer);SCNView 默认使用
        // 场景中的第一个相机节点,本场景仅此一个相机,行为确定。
        scnScene.rootNode.addChildNode(cameraNode)
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying { startAnimation() } else { stopAnimation() }
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
