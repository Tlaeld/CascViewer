# M3 材质类型渲染开关 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在模型预览器中加入齿轮弹层,让用户按 12 种 M3 材质类型控制渲染可见性,设置全局持久。

**Architecture:** loader 全量加载所有 region 并为每个网格打 `materialType` 标签;`ModelSceneBuilder` 按 `AppSettings.hiddenM3MaterialTypes`(UserDefaults 持久)在构建期过滤;预览器弹层修改设置后用内存中的 ModelScene 即时重建场景。

**Tech Stack:** Swift / SwiftUI / SceneKit / C++20(WhiteoutBridge)/ XCTest。

**Spec:** `docs/superpowers/specs/2026-08-14-m3-material-type-visibility-design.md`

## Global Constraints

- **禁止新建 .swift/.cpp 文件**:`CascViewer.xcodeproj/project.pbxproj` 是手工维护的显式文件列表(无 PBXFileSystemSynchronizedRootGroup),新文件需要手工加工程条目。新代码全部并入本计划指定的现有文件。
- 提交信息用英文,`feat:`/`fix:` 前缀风格。
- 本地化键必须同时加入 `CascViewer/Resources/en.lproj/Localizable.strings` 和 `CascViewer/Resources/zh-Hans.lproj/Localizable.strings`。
- 真实存储测试从 `~/.cascviewer-test-storages` 读取本机存储路径并以 `FileManager.fileExists(atPath:)` 门控,无存储时 XCTSkip,不算失败。
- 测试命令(定向):
  `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/<Class>/<test> 2>&1 | grep -E "Test Case.*(passed|failed)|error:" | tail -5`
- 测试命令(全量):
  `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test 2>&1 | grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED" | tail -3`
- 基线:116 tests / 0 failures / 1 skipped。

---

### Task 1: WOMesh/ModelScene 增加 materialType,M3 loader 全量加载并打标签

**Files:**
- Modify: `CascViewer/Core/WhiteoutBridge/include/WOModel.h:42-50`
- Modify: `CascViewer/Core/WhiteoutBridge/src/WOModelLoaderM3.cpp:150-200`
- Modify: `CascViewer/Core/Models/ModelScene.swift:17-25`
- Modify: `CascViewer/Core/Services/ModelSceneConverter.swift:60-68`
- Test: `CascViewerTests/ModelLoaderServiceTests.swift`(testGoldenDeathRender,约 361-369 行)

**Interfaces:**
- Produces: `WOMesh.materialType: uint32_t`(默认 1);`ModelScene.Mesh.materialType: Int`(默认 1)。M3 loader 写入 M3 MaterialType 原始值(1~12),无 batch 或越界保持 0(未知,上层默认可见)。MDX/M2 loader 与 C++ 测试夹具**不改**(走默认值 1)。

- [ ] **Step 1: 修改测试(先失败)**

`CascViewerTests/ModelLoaderServiceTests.swift` 中 testGoldenDeathRender,把:

```swift
        // 8 个 region 中 1 个是 Displacement(地面压平)材质,不可渲染已跳过
        XCTAssertEqual(scene.meshes.count, 7)
```

改为:

```swift
        // loader 全量加载所有 region;region[5] 是 Displacement(type=2),其余为 Standard(type=1)。
        // 可见性过滤在构建期(ModelSceneBuilder)进行,不在 loader。
        XCTAssertEqual(scene.meshes.count, 8)
        XCTAssertEqual(scene.meshes.map(\.materialType), [1, 1, 1, 1, 1, 2, 1, 1])
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/ModelLoaderServiceTests/testGoldenDeathRender 2>&1 | grep -E "Test Case.*(passed|failed)|error:" | tail -5`
Expected: FAIL(meshes.count 实际为 7,或 materialType 属性不存在导致编译错误)

- [ ] **Step 3: 实现**

`WOModel.h` 的 `WOMesh` 结构体,在 `int32_t materialIndex = -1;` 后加一行:

```cpp
    int32_t materialIndex = -1;
    uint32_t materialType = 1;      // M3 MaterialType 原始值;0=未知(默认可见);MDX/M2 恒为 1(Standard)
```

`WOModelLoaderM3.cpp` 的 region 循环,**删除**之前加入的可渲染性跳过块:

```cpp
            const auto& region = div.regions[ri];
            // 只渲染 Standard / Composite 材质的 region。Displacement、Terrain、
            // Volume、Creep 等是地面压平/特效网格(以真实文件验证:zealot_golden_death
            // 的 Displacement region 渲染成一块大灰椭圆),直接跳过。
            bool renderable = true;
            for (const auto& batch : div.batches) {
                if (batch.regionIndex == ri) {
                    if (batch.materialIndex < model.materialMaps.size()) {
                        const auto mt = model.materialMaps[batch.materialIndex].materialType;
                        renderable = (mt == m3::MaterialType::Standard ||
                                      mt == m3::MaterialType::Composite);
                    }
                    break;
                }
            }
            if (!renderable) continue;

            WOMesh mesh;
```

恢复为:

```cpp
            const auto& region = div.regions[ri];
            WOMesh mesh;
```

同一文件中,把 batch 查找块:

```cpp
            // 材质:找引用该 region 的 batch
            for (const auto& batch : div.batches) {
                if (batch.regionIndex == ri) {
                    mesh.materialIndex = (int32_t)batch.materialIndex;  // 与 materialMaps 对齐
                    break;
                }
            }
```

改为:

```cpp
            // 材质:找引用该 region 的 batch;记录 M3 材质类型供上层按类型过滤渲染
            // (无 batch 或索引越界保持默认 1;显式标 0 的语义留给未来,当前不设)
            for (const auto& batch : div.batches) {
                if (batch.regionIndex == ri) {
                    mesh.materialIndex = (int32_t)batch.materialIndex;  // 与 materialMaps 对齐
                    if (batch.materialIndex < model.materialMaps.size())
                        mesh.materialType = (uint32_t)model.materialMaps[batch.materialIndex].materialType;
                    break;
                }
            }
```

注意:无 batch 时 `materialType` 保持 WOMesh 默认值 1(Standard,可见)——fail-open。

`ModelScene.swift` 的 `Mesh` 结构体,在 `var materialIndex: Int` 行后加:

```swift
        var materialIndex: Int           // -1 = 无
        /// M3 材质类型原始值(1~12,见 M3MaterialKind);默认 Standard,
        /// 使现有构造点与 MDX/M2 路径无需修改。
        var materialType: Int = 1
```

`ModelSceneConverter.swift` 的 Mesh 构造(60-68 行),把:

```swift
                materialIndex: Int(m.materialIndex)
            )
```

改为:

```swift
                materialIndex: Int(m.materialIndex),
                materialType: Int(m.materialType)
            )
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: `Test Case '-[CascViewerTests.ModelLoaderServiceTests testGoldenDeathRender]' passed`

- [ ] **Step 5: 全量回归**

Run: 全量命令
Expected: `Executed 116 tests, with 1 test skipped and 0 failures` + `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add CascViewer/Core/WhiteoutBridge/include/WOModel.h \
        CascViewer/Core/WhiteoutBridge/src/WOModelLoaderM3.cpp \
        CascViewer/Core/Models/ModelScene.swift \
        CascViewer/Core/Services/ModelSceneConverter.swift \
        CascViewerTests/ModelLoaderServiceTests.swift
git commit -m "feat: tag M3 meshes with material type and load all regions"
```

---

### Task 2: M3MaterialKind 元数据 + AppSettings.hiddenM3MaterialTypes + 本地化

**Files:**
- Modify: `CascViewer/Core/Models/ModelScene.swift`(文件末尾追加 enum)
- Modify: `CascViewer/App/AppSettings.swift`
- Modify: `CascViewer/Resources/en.lproj/Localizable.strings`
- Modify: `CascViewer/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `CascViewerTests/AppSettingsTests.swift`(末尾追加 3 个测试)

**Interfaces:**
- Consumes: Task 1 的 `materialType` 语义。
- Produces: `M3MaterialKind`(Int raw 1~12,`CaseIterable, Identifiable`;`displayName: String`;`descriptionKey: String`;`static let defaultHidden: Set<Int>`);`AppSettings.hiddenM3MaterialTypes: Set<Int>`。Task 3/4 依赖这两个名字。

- [ ] **Step 1: 写失败测试**

`CascViewerTests/AppSettingsTests.swift` 类内末尾追加:

```swift
    func testHiddenM3MaterialTypesDefault() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hiddenM3MaterialTypes, M3MaterialKind.defaultHidden)
        XCTAssertFalse(settings.hiddenM3MaterialTypes.contains(1))  // Standard 默认可见
        XCTAssertFalse(settings.hiddenM3MaterialTypes.contains(3))  // Composite 默认可见
        XCTAssertTrue(settings.hiddenM3MaterialTypes.contains(2))   // Displacement 默认隐藏
    }

    func testHiddenM3MaterialTypesPersistence() {
        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.hiddenM3MaterialTypes = [5]
        settings = nil
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hiddenM3MaterialTypes, [5])
    }

    func testHiddenM3MaterialTypesReset() {
        let settings = AppSettings(defaults: defaults)
        settings.hiddenM3MaterialTypes = []
        settings.resetToDefaults()
        XCTAssertEqual(settings.hiddenM3MaterialTypes, M3MaterialKind.defaultHidden)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/AppSettingsTests 2>&1 | grep -E "Test Case.*(passed|failed)|error:" | tail -8`
Expected: 编译错误(`M3MaterialKind` / `hiddenM3MaterialTypes` 不存在)

- [ ] **Step 3: 实现**

`ModelScene.swift` 文件末尾(74 行 `}` 之后)追加:

```swift

/// M3 材质类型(MAT_ 等 chunk 的 materialType 原始值)。
/// 仅用于按类型过滤渲染;MDX/M2 无此概念,网格恒为 1(Standard)。
enum M3MaterialKind: Int, CaseIterable, Identifiable {
    case standard = 1
    case displacement = 2
    case composite = 3
    case terrain = 4
    case volume = 5
    case volumeNoise = 6
    case creep = 7
    case hair = 8
    case splatTerrainBake = 9
    case reflection = 10
    case lensFlare = 11
    case bufferMaterial = 12

    var id: Int { rawValue }

    /// 默认隐藏的类型:非实体表面(地形系统/体积特效/数据缓冲等)。
    /// 即 Standard(1)与 Composite(3)之外的全部。
    static let defaultHidden: Set<Int> = [2, 4, 5, 6, 7, 8, 9, 10, 11, 12]

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .displacement: return "Displacement"
        case .composite: return "Composite"
        case .terrain: return "Terrain"
        case .volume: return "Volume"
        case .volumeNoise: return "Volume Noise"
        case .creep: return "Creep"
        case .hair: return "Hair"
        case .splatTerrainBake: return "Splat Terrain Bake"
        case .reflection: return "Reflection"
        case .lensFlare: return "Lens Flare"
        case .bufferMaterial: return "Buffer Material"
        }
    }

    /// Localizable.strings 中的说明文案键(m3mat_desc_1 ~ m3mat_desc_12)
    var descriptionKey: String { "m3mat_desc_\(rawValue)" }
}
```

`AppSettings.swift`:

(a) 在 `@Published var useBuiltInModelViewer: Bool { ... }` 声明块之后加:

```swift
    /// 隐藏的 M3 材质类型(原始值集合);默认只显示 Standard/Composite。
    @Published var hiddenM3MaterialTypes: Set<Int> {
        didSet { defaults.set(hiddenM3MaterialTypes.sorted(), forKey: "hiddenM3MaterialTypes") }
    }
```

(b) `init` 中 `self.useBuiltInModelViewer = ...` 行之后加:

```swift
        self.hiddenM3MaterialTypes = (defaults.array(forKey: "hiddenM3MaterialTypes") as? [Int])
            .map(Set.init) ?? M3MaterialKind.defaultHidden
```

(c) `resetToDefaults()` 中 `useBuiltInModelViewer = true` 行之后加:

```swift
        hiddenM3MaterialTypes = M3MaterialKind.defaultHidden
```

`en.lproj/Localizable.strings` 追加:

```
"render_settings" = "Render Settings";
"m3mat_desc_1" = "Standard material (solid surface)";
"m3mat_desc_2" = "Ground-flattening mesh, usually not displayed";
"m3mat_desc_3" = "Composite multi-layer material (rendered as placeholder)";
"m3mat_desc_4" = "Terrain material";
"m3mat_desc_5" = "Volume effect mesh (smoke, clouds)";
"m3mat_desc_6" = "Volume noise effect";
"m3mat_desc_7" = "Creep projection";
"m3mat_desc_8" = "Hair (defunct)";
"m3mat_desc_9" = "Splat terrain bake";
"m3mat_desc_10" = "Reflection material";
"m3mat_desc_11" = "Lens flare";
"m3mat_desc_12" = "Additional data buffer";
```

`zh-Hans.lproj/Localizable.strings` 追加:

```
"render_settings" = "渲染设置";
"m3mat_desc_1" = "标准材质(实体表面)";
"m3mat_desc_2" = "地面压平网格,通常无需显示";
"m3mat_desc_3" = "多层合成材质(暂以占位渲染)";
"m3mat_desc_4" = "地形材质";
"m3mat_desc_5" = "体积特效网格(烟雾、云雾)";
"m3mat_desc_6" = "体积噪声特效";
"m3mat_desc_7" = "菌毯投影";
"m3mat_desc_8" = "毛发(已废弃)";
"m3mat_desc_9" = "地形烘焙";
"m3mat_desc_10" = "反射材质";
"m3mat_desc_11" = "镜头光晕";
"m3mat_desc_12" = "附加数据缓冲";
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: 3 个新测试全 `passed`

- [ ] **Step 5: Commit**

```bash
git add CascViewer/Core/Models/ModelScene.swift CascViewer/App/AppSettings.swift \
        CascViewer/Resources/en.lproj/Localizable.strings \
        CascViewer/Resources/zh-Hans.lproj/Localizable.strings \
        CascViewerTests/AppSettingsTests.swift
git commit -m "feat: persist hidden M3 material types in AppSettings"
```

---

### Task 3: ModelSceneBuilder 构建期过滤

**Files:**
- Modify: `CascViewer/Core/Services/ModelSceneBuilder.swift:21,47`
- Modify: `CascViewerTests/ModelLoaderServiceTests.swift`(testGoldenDeathRender 的 build 调用,约 374 行)
- Test: `CascViewerTests/ModelSceneBuilderTests.swift`(末尾追加测试)

**Interfaces:**
- Consumes: `M3MaterialKind.defaultHidden`(Task 2)。
- Produces: `ModelSceneBuilder.build(_ scene: ModelScene, hiddenMaterialTypes: Set<Int> = []) -> BuiltModelScene`。Task 4 的 UI 全部经此签名调用。

- [ ] **Step 1: 写失败测试**

`CascViewerTests/ModelSceneBuilderTests.swift` 的 `ModelSceneBuilderTests` 类末尾追加:

```swift
    func testBuildFiltersHiddenMaterialTypes() {
        var scene = makeScene()
        var extra = scene.meshes[0]
        extra.materialType = 2  // Displacement
        scene.meshes.append(extra)
        let unfiltered = ModelSceneBuilder.build(scene)
        XCTAssertEqual(unfiltered.rootNode.childNodes.filter { $0.geometry != nil }.count, 2)
        let filtered = ModelSceneBuilder.build(scene, hiddenMaterialTypes: [2])
        XCTAssertEqual(filtered.rootNode.childNodes.filter { $0.geometry != nil }.count, 1)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/ModelSceneBuilderTests/testBuildFiltersHiddenMaterialTypes 2>&1 | grep -E "Test Case.*(passed|failed)|error:" | tail -5`
Expected: 编译错误(`hiddenMaterialTypes` 参数不存在)

- [ ] **Step 3: 实现**

`ModelSceneBuilder.swift`:

(a) `build` 签名(21 行)改为:

```swift
    static func build(_ scene: ModelScene, hiddenMaterialTypes: Set<Int> = []) -> BuiltModelScene {
```

(b) 网格循环(47 行)把:

```swift
        for mesh in scene.meshes {
```

改为:

```swift
        // 按材质类型过滤(M3 渲染设置控制;默认空集 = 全部可见)
        for mesh in scene.meshes where !hiddenMaterialTypes.contains(mesh.materialType) {
```

(c) `CascViewerTests/ModelLoaderServiceTests.swift` testGoldenDeathRender 中,把:

```swift
        // 离屏渲染存档(人工查看)
        let built = ModelSceneBuilder.build(scene)
```

改为:

```swift
        // 离屏渲染存档(人工查看);按默认隐藏集过滤,存档图不含 Displacement 网格
        let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
```

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: 先定向(同 Step 2),再全量
Expected: 定向 `passed`;全量 `Executed 120 tests, with 1 test skipped and 0 failures` + `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add CascViewer/Core/Services/ModelSceneBuilder.swift \
        CascViewerTests/ModelSceneBuilderTests.swift \
        CascViewerTests/ModelLoaderServiceTests.swift
git commit -m "feat: filter meshes by material type in ModelSceneBuilder"
```

---

### Task 4: 预览器齿轮弹层 + 场景重建

**Files:**
- Modify: `CascViewer/UI/ModelViewer/ModelViewerWindow.swift`(工具栏齿轮 + 弹层视图 + viewModel.rebuild)
- Modify: `CascViewer/UI/FileBrowser/FilePreviewPanel.swift:161`
- Modify: `CascViewer/UI/FileBrowser/FileListView.swift:186`
- Test: `CascViewerTests/ModelSceneBuilderTests.swift`(文件末尾追加 `ModelViewerViewModelTests` 类)

**Interfaces:**
- Consumes: `AppSettings.shared.hiddenM3MaterialTypes`(Task 2)、`ModelSceneBuilder.build(_:hiddenMaterialTypes:)`(Task 3)、`M3MaterialKind.allCases / displayName / descriptionKey`(Task 2)。
- Produces: `ModelViewerViewModel.rebuild(with built: BuiltModelScene)`;`ModelViewerViewModel.setup` 保留原签名。

- [ ] **Step 1: 写失败测试**

`CascViewerTests/ModelSceneBuilderTests.swift` **文件末尾**(最后一个 `}` 之后)追加:

```swift

@MainActor
final class ModelViewerViewModelTests: XCTestCase {

    private func makeScene() -> ModelScene {
        let mesh = ModelScene.Mesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
            indices: [0, 1, 2],
            boneIndices: [], boneWeights: [],
            materialIndex: 0
        )
        let material = ModelScene.Material(
            texturePath: "", textureFileDataId: 0, blendMode: .opaque,
            twoSided: false, unlit: false, diffuseTexture: nil
        )
        return ModelScene(
            name: "t", format: .m3, meshes: [mesh], materials: [material],
            bones: [], animations: [],
            boundsMin: .zero, boundsMax: SIMD3(1, 1, 1)
        )
    }

    /// 重建后:场景被替换、隐藏类型不再有几何节点、相机节点复用(保留用户视角)
    func testRebuildSwapsSceneKeepsCameraAndFilters() {
        let vm = ModelViewerViewModel()
        let scene = makeScene()
        vm.setup(scene: scene, built: ModelSceneBuilder.build(scene))
        let camera = vm.cameraNode
        XCTAssertNotNil(camera)
        // 隐藏唯一网格的类型(1),重建后场景中不应再有几何节点
        vm.rebuild(with: ModelSceneBuilder.build(scene, hiddenMaterialTypes: [1]))
        XCTAssertTrue(vm.cameraNode === camera)
        XCTAssertTrue(vm.scnScene.rootNode.childNodes.contains { $0 === camera })
        var geoCount = 0
        vm.scnScene.rootNode.enumerateChildNodes { node, _ in
            if node.geometry != nil { geoCount += 1 }
        }
        XCTAssertEqual(geoCount, 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/ModelViewerViewModelTests 2>&1 | grep -E "Test Case.*(passed|failed)|error:" | tail -5`
Expected: 编译错误(`rebuild(with:)` 不存在)

- [ ] **Step 3: 实现**

`ModelViewerWindow.swift`:

(a) `ModelViewerWindow` 结构体加 state(在 `@StateObject private var viewModel` 行后):

```swift
    @StateObject private var viewModel = ModelViewerViewModel()
    @State private var showRenderSettings = false
```

(b) 工具栏 HStack 中,动画控制块(`if !viewModel.player.animationNames.isEmpty { ... } else { ... }`)**之后**、`.padding()` 之前加:

```swift
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
```

(c) `ModelViewerViewModel` 加存储属性与重建方法。在 `private var displayLink: CVDisplayLink?` 前加:

```swift
    private var modelScene: ModelScene?
```

`setup` 第一行改为:

```swift
    func setup(scene: ModelScene, built: BuiltModelScene) {
        modelScene = scene
```

在 `togglePlayback()` 方法后加:

```swift
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
```

(d) `ModelViewerWindow.swift` 文件末尾(`openModelViewerWindow` 函数之后)追加弹层视图:

```swift

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
```

(e) 打开预览器的两处初始构建也带上设置。`FilePreviewPanel.swift:161` 与 `FileListView.swift:186`,把:

```swift
let built = ModelSceneBuilder.build(scene)
```

改为:

```swift
let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: AppSettings.shared.hiddenM3MaterialTypes)
```

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: 先定向(同 Step 2),再全量
Expected: 定向 `passed`;全量 `Executed 121 tests, with 1 test skipped and 0 failures` + `** TEST SUCCEEDED **`

- [ ] **Step 5: 人工验证(需要真机存储)**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug build 2>&1 | tail -2
open "build/Debug/CascViewer.app"  # 或从 Xcode 运行
```

打开 `mods/liberty.sc2mod/base.sc2assets/assets/units/protoss/zealot_golden_death/zealot_golden_death.m3`:
- 默认应与修复后一致:金色 Zealot,无灰椭圆、无白块;
- 点齿轮打开 Displacement 开关 → 大灰椭圆立即出现;关闭 → 消失;
- 动画选择与播放状态不被重置;
- 重启 app 后再开任意 M3,开关状态保持。

- [ ] **Step 6: Commit**

```bash
git add CascViewer/UI/ModelViewer/ModelViewerWindow.swift \
        CascViewer/UI/FileBrowser/FilePreviewPanel.swift \
        CascViewer/UI/FileBrowser/FileListView.swift \
        CascViewerTests/ModelSceneBuilderTests.swift
git commit -m "feat: material-type visibility popover in model viewer"
```

---

## Self-Review 记录

- **Spec 覆盖**:loader 全量+标签(Task 1)、AppSettings 持久 + 默认值 + reset(Task 2)、builder 过滤(Task 3)、齿轮弹层仅 M3 + 重建保留动画/相机(Task 4)、本地化(Task 2)、测试(每个 Task)。无遗漏。
- **占位符**:无 TBD/TODO;所有代码完整。
- **类型一致性**:`M3MaterialKind.defaultHidden: Set<Int>` 与 `AppSettings.hiddenM3MaterialTypes: Set<Int>`、`build(_:hiddenMaterialTypes: Set<Int>)`、弹层 `onChange: (Set<Int>) -> Void` 全部对齐;`descriptionKey` 命名 `m3mat_desc_<raw>` 与 strings 键一致。
- **关键决策**(与 pbxproj 手工维护约束一致):M3MaterialKind 并入 `ModelScene.swift`,弹层并入 `ModelViewerWindow.swift`,viewModel 测试并入 `ModelSceneBuilderTests.swift`,不新建任何文件。
