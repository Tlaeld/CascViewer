# WhiteoutLib 接入设计:纹理解码替换 + 3D 模型预览

日期:2026-08-10
状态:已通过设计评审,待实施

## 背景与目标

CascViewer 目前的手写格式解析代码只有 `Core/CASCBridge/src/BLPDecoderBridge.cpp`(约 1008 行,BLP1/BLP2/DDS → RGBA8888)。本项目的目标是:

1. **纹理解码**:删除手写的 `BLPDecoderBridge`,改用 [WhiteoutLib](https://github.com/FernandoS27/WhiteoutLib) 的 textures 模块(BLP1/BLP2/DDS parser)。
2. **3D 模型预览(新功能)**:用 WhiteoutLib 的 models 模块(MDX / M3 / M2 parser)新增带骨骼动画的 3D 模型预览。

**明确不做**:CascLib 及其桥接层(`LocalCascStorage`、`CDNConfig`、`CDNCacheManager` 等)全部保留不动。WhiteoutLib 不启用其 CASC/MPQ 模块(`WHITEOUT_ENABLE_CASC=OFF`,默认即 OFF),与 CascLib 零重叠、零符号冲突。

## 方案选型(已确认)

- **方案 A**:CMake 静态库 + 薄 C++ 桥 + SceneKit 渲染。已否决:Metal 渲染(此场景性能无差别,多约 1500+ 行)、Swift 直接 C++ interop 导入 WhiteoutLib(`std::optional`/`std::span`/`std::function` 导入受限,脆弱)。
- **格式范围**:MDX + M3 + M2 三个都要。注意 WhiteoutLib 的 M2 parser 仍是实验性(缺少 MoP 之前版本的解析、无 `.phys`/`.bone`),部分 WoW 模型可能解析失败,按错误路径处理。
- **预览深度**:静态模型 + 纹理 + 骨骼动画播放。

## 总体架构

```
SwiftUI ──> Swift 服务层 ──> WhiteoutBridge(新薄 C++ 桥)──> WhiteoutLib(静态库)
                │
                └──> 现有 CascBridge(CascLib)────────── 不动,继续负责存储 I/O
```

## 组件设计

### 1. WhiteoutLib vendor 与构建

- 作为 git 子模块加入 `WhiteoutLib/`(与 CascLib 同模式)。
- 新增 `tools/build_whiteout.sh`:调用 CMake 构建 Release 版 `libwhiteout_lib.a`,arm64 与 x86_64 分别构建后用 `lipo` 合并为 universal 静态库,输出到 `WhiteoutLib/build-universal/`(gitignore)。
- CMake 配置:`-DWHITEOUT_ENABLE_CASC=OFF -DWHITEOUT_ENABLE_MPQ=OFF -DCMAKE_BUILD_TYPE=Release`。
- Xcode 工程:链接该静态库;`HEADER_SEARCH_PATHS` 增加 `$(SRCROOT)/WhiteoutLib/include`。不把 WhiteoutLib 源码加入 Xcode target。

### 2. WhiteoutBridge(新 C++ 薄桥,约 500 行)

位置:`CascViewer/Core/WhiteoutBridge/include/` + `src/`。边界只出 POD 值类型与 `std::string`/`std::vector`,不暴露 `std::optional`/`std::span`/`std::function`。

- **`WOTextureDecoder`**:包装 `whiteout::textures::blp::Parser` / `dds::Parser`。
  - 输入:文件字节(buffer + size)。
  - 输出:对齐现有 `ImageDecodeResult` 的形状(format、compression、mip levels、RGBA8888 帧数组),使 `BLPDecoderCoordinator` 的改动最小。
- **`WOModelLoader`**:包装 MDX / M3 / M2 parser,统一为渲染无关的场景描述 `WOModel`:
  - 网格:顶点(position/normal/uv)、索引、骨骼权重与骨骼索引。
  - 材质:纹理引用(MDX/M3 为路径字符串;M2 为 FileDataId 或纹理名)、blend mode、双面/unlit 等标志。
  - 骨骼:层级、逆绑定矩阵。
  - 动画:命名序列列表,每骨骼的 position/rotation/scale 关键帧轨道。
- 错误模型:WhiteoutLib parser 返回 `std::optional`,桥内映射为 `WOError` 枚举 + 消息字符串。

### 3. Swift 服务层

- **`BLPDecoderCoordinator`**:内部从 `ImageDecoderBridge` 切换到 `WOTextureDecoder`,**对外 API 不变**(现有 BLPViewer、测试不受影响)。
- **删除**:`Core/CASCBridge/src/BLPDecoderBridge.cpp`、`Core/CASCBridge/include/BLPDecoderBridge.h`(约 1055 行),并从 bridging umbrella header / modulemap / pbxproj 移除引用。
- **`ModelLoaderService`**(新,actor):
  1. 通过现有 `CASCStorageService`(CascLib)读模型文件字节;
  2. 调 `WOModelLoader` 解析;
  3. 逐材质解析纹理引用 → 从存储读纹理字节 → `WOTextureDecoder` 解码 → `CGImage`;
  4. 产出 Swift 值类型 `ModelScene`(网格/材质/骨骼/动画树)。
  - 带 `NSCache` 缓存(与 `BLPDecoderCoordinator` 同款模式)。
- **`ModelSceneBuilder`**(新):`ModelScene` → SceneKit 节点图。
  - 骨骼 → `SCNNode` 树;网格 + 权重 + 逆绑定矩阵 → `SCNSkinner`(GPU 蒙皮);
  - 纹理 → `SCNMaterial`(blend mode 映射:opaque / alpha test / additive;doubleSided;unlit → constant lighting model)。
- **`ModelAnimationPlayer`**(新):每帧(约 60fps Timer)在 CPU 求值动画轨道(position/rotation/scale 插值)→ 赋给骨骼 `SCNNode` 变换;蒙皮由 `SCNSkinner` 完成。

### 4. UI

- **`UI/ModelViewer/`**(新):
  - `ModelViewerWindow`:独立 NSWindow,复用 `BLPViewerWindow` 的窗口模式;
  - `ModelViewerView`:`NSViewRepresentable` 包装 `SCNView`,`allowsCameraInteraction = true`(轨道相机免费获得);
  - 动画控件:序列选择器 + 播放/暂停 + 时间滑块。
- **入口**:`FilePreviewPanel` 识别 `.mdx` / `.m3` / `.m3a` / `.m2` 扩展名,提供"在 Model Viewer 中打开"(与 BLP 入口模式一致)。

## 数据流(3D 预览)

1. 用户点击模型文件 → `FilePreviewPanel` 识别扩展名 → 打开 ModelViewer。
2. `ModelLoaderService` 经 CascLib 读模型字节。
3. `WOModelLoader.parse` → `WOModel`。
4. 纹理引用逐个经存储读取 + `WOTextureDecoder` 解码为 `CGImage`。
5. `ModelSceneBuilder` → SceneKit 场景。
6. 用户选择动画序列 → `ModelAnimationPlayer` 驱动骨骼。

## 错误处理

- **解析失败**(实验性 M2、过老/未知格式变体):桥返回 `WOError` + 消息;UI 显示"无法解析该模型"占位面板,不崩溃。
- **纹理缺失**(存储中找不到引用):占位灰色材质,模型照常显示。
- **不支持的格式**:同解析失败路径。
- WhiteoutLib lenient parser 的 issue list 不向上暴露,仅在 DEBUG 下打日志。

## 测试

- **零版权素材原则**:不把暴雪游戏资源放进仓库。用 WhiteoutLib 自带的 MDX / M3 / BLP **writer** 在测试里现场生成字节 → 再 parse 回来做 round-trip 断言。
- 新增测试:
  - `WOTextureDecoder` 桥测试(writer 生成 BLP → 解码 → 断言尺寸/格式/像素非空);
  - `WOModelLoader` 桥测试(writer 生成 MDX/M3 → 解析 → 断言网格/骨骼/动画结构);
  - `ModelSceneBuilder` 结构测试(节点数、蒙皮绑定、材质映射)。
- 现有 74 个测试保持通过(`BLPDecoderCoordinator` 对外 API 不变;`BridgeTests` 中针对被删 `BLPDecoderBridge` 的用例改为走新桥)。

## 影响面清单

| 动作 | 文件 |
|---|---|
| 新增子模块 | `WhiteoutLib/` |
| 新增 | `tools/build_whiteout.sh` |
| 新增 | `CascViewer/Core/WhiteoutBridge/`(约 4-6 个文件,~500 行) |
| 新增 | `CascViewer/Core/Services/ModelLoaderService.swift`、`ModelSceneBuilder.swift`、`ModelAnimationPlayer.swift` |
| 新增 | `CascViewer/UI/ModelViewer/`(3-4 个文件) |
| 修改 | `BLPDecoderCoordinator.swift`(内部切换,API 不变) |
| 修改 | `CascViewer-Bridging-Header.h` / `module.modulemap`(去掉 BLPDecoderBridge,加 WhiteoutBridge) |
| 修改 | `FilePreviewPanel.swift`(模型入口) |
| 修改 | `project.pbxproj`(删 BLPDecoderBridge、加 WhiteoutBridge 源文件、链接静态库、头文件路径) |
| 删除 | `Core/CASCBridge/src/BLPDecoderBridge.cpp`、`include/BLPDecoderBridge.h` |
| 新增测试 | `CascViewerTests/WhiteoutBridgeTests.swift`、`ModelSceneBuilderTests.swift` |
| 修改文档 | `README.md` / `README.zh.md` 架构图(加 WhiteoutBridge + ModelViewer) |

## 风险

- **M2 实验性**:部分 WoW 模型解析失败属预期,走错误路径;在 UI 文案中如实提示。
- **M2 纹理引用解析**:WoW 纹理常以 FileDataId 或变体名引用,解析规则需在实施时按实际样本验证,失败时降级为占位材质。
- **WhiteoutLib beta**:API 可能跨版本变动;子模块 pin 到具体 commit,升级单独评估。

## 实施裁剪记录

- 时间滑块未实现(序列选择器 + 播放/暂停已含)。
- 解析失败为全局错误提示,而非"无法解析该模型"占位面板。
- WhiteoutLib issue list 的 DEBUG 日志未实现(issue list 不向上暴露,也未打日志)。
