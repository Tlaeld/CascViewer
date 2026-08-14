# 模型预览器材质类型渲染开关 — 设计文档

日期:2026-08-14
状态:已确认(用户选定方案 A)

## 背景

M3 模型的 region 可能引用 12 种材质类型(Standard、Displacement、Composite、Terrain、
Volume、VolumeNoise、Creep、Hair、SplatTerrainBake、Reflection、LensFlare、BufferMaterial)。
其中只有 Standard/Composite 是实体表面;其余多为地形系统、体积特效或数据缓冲,
直接渲染会出现大灰椭圆等错误画面(commit d236da2 在 loader 中硬编码跳过)。

用户需求:不硬编码,在**内置模型预览器**中提供设置,让用户随时自行控制各类材质是否渲染。

## 已确认的决策

- **作用范围**:全局持久生效,存 `AppSettings`(UserDefaults),重启保留。
- **UI 形态**:预览器工具栏齿轮按钮 + 弹出层(popover),不做进 app 外部设置页。
- **选项粒度**:固定列出全部 12 种 M3 材质类型。

## 方案(A):全量加载 + 构建期过滤

否决的备选:B(全部构建 + 切 isHidden,隐藏网格残留场景图);C(改设置后重载文件,管道多且慢)。

### 1. 数据流

- `WOMesh` 与 `ModelScene.Mesh` 新增 `materialType: Int`(M3 原始类型值 1~12)。
- `WOModelLoaderM3.cpp`:删除 region 跳过逻辑,所有 region 都产出网格;
  region → batch → materialMaps 查得的类型写入 `mesh.materialType`;
  无 batch 或索引越界时保持默认值 1(fail-open,可见;不产出 0)。
- MDX/M2 loader 及 C++ 测试夹具(WOEncodeTestM3/MDX/M2):一律填 1(Standard),保证现有行为与测试不变。

### 2. 设置存储

- `AppSettings` 新增 `@Published var hiddenM3MaterialTypes: Set<Int>`,
  UserDefaults 键 `hiddenM3MaterialTypes`(Int 数组)。
- 默认值 `[2,4,5,6,7,8,9,10,11,12]`(即现状:仅 Standard/Composite 可见)。
- `resetToDefaults()` 一并重置。

### 3. 预览器 UI

- `ModelViewerWindow` 工具栏(动画选择器旁)新增齿轮按钮,仅 `format == .m3` 时显示。
- 点击弹出 popover:12 个 Toggle,每项显示英文名 + 一句中文说明
  (如 Displacement — "地面压平网格,通常无需显示")+ 当前模型该类型的网格数。
- 拨动开关 → 写入 `AppSettings` → viewModel 用**内存中已有的 ModelScene** 重新
  `ModelSceneBuilder.build`,替换场景;保留当前动画索引与播放/暂停状态,
  播放进度重置为 0(重建即时完成,影响可忽略)。
- 材质类型元数据(名称/说明)放一个 Swift 端小枚举,本地化走 `L()` 键(zh/en)。

### 4. 场景构建

- `ModelSceneBuilder.build(_:)` 增加显式 `hiddenMaterialTypes` 参数(默认 `[]`,
  由调用方传入 AppSettings 中的设置,测试可显式传入):
  `mesh.materialType` 在隐藏集合中的网格不生成节点。

## 测试

- loader:golden_death 断言回到 8 个网格,并校验各网格 `materialType`
  (region[5] 对应 Displacement=2)。
- builder:默认设置下 golden_death 构建结果 7 个网格节点;全部开启后 8 个。
- AppSettings:`hiddenM3MaterialTypes` 持久化 round-trip + `resetToDefaults`。
- 现有 116 个测试不受影响(夹具与 MDX/M2 类型恒为 1,永远可见)。

## 非目标(YAGNI)

- 不做体积特效(Volume)的真实渲染,只做"显示/隐藏"。
- 不做逐网格、逐材质实例的开关,只按类型。
- MDX/M2 不提供该面板(无此概念)。
