# 主窗口 + 搜索窗口 UI 翻新 — 设计文档

日期:2026-08-16
分支:`feat/main-ui-refresh`(从 `main` 拉出)
范围:主文件浏览器窗口 + 搜索窗口。模型查看器、BLP 查看器、安装清单等窗口不动。

## 1. 背景与问题诊断

用户反馈:主窗口 UI 老旧、操作手感别扭,且"点开一个目录会自动收起另一个目录"。

代码勘察(`CascViewer/UI/`)定位的根因:

1. **自动收起 bug**:`FileBrowser/FileTreeView.swift:131`
   `.onChange(of: storage.currentChildren)` 时 `expandedPaths.removeAll()`。
   而 `CASCStorageService.navigate(to:)`(`Core/Services/CASCStorageService.swift:880`)每次导航都会改
   `currentChildren`,导致任何导航(点树行、双击列表目录、点面包屑)都清空整棵树的展开状态,
   随后只恢复当前路径的祖先链。该代码本意是"存储重载时重置展开",但把"导航"和"重载"混为一谈。
2. **老旧感来源**:手写分栏拖拽条(非系统分隔)、▼/▶ 文字按钮当展开指示、
   硬编码字体(11/12/13 散落各视图)、无设计系统(颜色各处临时取)、面包屑/状态栏样式旧。
3. **手感差来源**:reload 后按行号恢复选择(上方行展开后选择错位并 scrollRowToVisible 跳动)、
   `toggleExpand` 抑制选择的逻辑跨 run-loop、排序异步闪动。

性能约束(翻新不得破坏):CASC 存储可达几十万文件,目录树与文件列表当前基于
NSTableView 桥接的懒渲染,这是刻意为之,必须保留数据层性能。

## 2. 方案选择

- **A. 混合翻新(已批准)**:保留 NSTableView/数据层性能内核,重写外壳与视觉,修掉全部交互 bug。
- B. 纯 SwiftUI 重写(NavigationSplitView + Table/OutlineGroup):大树/大列表懒加载性能需重新验证,
  排序/选择/滚动恢复逻辑全部重写,风险最大 —— 否决。
- C. 最小修补:只修 bug 不调视觉,不治本 —— 否决。

## 3. 设计

### 3.1 布局(MainWindowView)

- `MainWindowView` 改 `NavigationSplitView`(侧栏 + 内容两栏),移除手写拖拽条与
  `@AppStorage("mainWindow.leftWidth")` 手动宽度持久化(改由系统 autosave)。
- 右侧内部:文件列表 + 可折叠详情面板(系统分隔,不再手写)。
- 工具栏并入系统 `.toolbar`,移除手写工具条行;窗口标题显示当前存储名。

### 3.2 目录树(FileTreeView 重写)

- 新建 `TreeExpansionStore`(`UI/FileBrowser/TreeExpansionStore.swift`,`@MainActor ObservableObject`):
  - 持有 `expandedPaths: Set<String>`,提供 `toggle(_:)` / `expand(_:)` / `expandAncestors(of:)`。
  - **navigate 时不清空**;仅当存储真正重载时清空。
  - `CASCStorageService` 增加 `entriesGeneration: Int`(loadStorage / refreshCurrentStorage 时 +1),
    树监听该 generation 变化才清空展开状态 —— 区分"重载"与"导航"。
- 树内部从"扁平行模型 + NSTableView + 文字 disclosure 按钮"换成 **NSOutlineView** 桥接:
  原生展开三角、展开/收起动画、键盘导航;数据源直接查 `childrenByPath`,保持懒渲染。
- 选择恢复全部 path-based(不再按行号),消除错位跳动。

### 3.3 文件列表(FileListView 视觉翻新)

- 保留 NSTableView 内核与现有排序/多选/双击导航/右键菜单逻辑。
- 重做 cell:SF Symbols 类型图标、行高与间距现代化、选中色与悬停态统一。
- 列头与排序指示器现代化;路径列自动隐藏逻辑保留。
- 远程文件红色标记(`AppSettings.showRemoteMarkers`)保留,改用设计系统语义色。

### 3.4 面包屑 / 详情面板 / 状态栏

- 面包屑:改系统风格分段控件样式(图标 + 分段按钮),行为不变(home/up/分段跳转)。
- 详情面板:卡片化布局,编码密钥用等宽字体,操作按钮样式统一。
- 状态栏:精简为单行(条目数 + 加载状态),样式并入设计系统。

### 3.5 设计系统(新建 `UI/DesignSystem.swift`)

- 语义色:sidebarBackground / rowHover / rowSelection / remoteFile / statusText 等,明暗双主题。
- 字体阶梯:caption / body / headline 三级,替代散落的硬编码 size。
- 间距与圆角常量。主窗口与搜索窗口统一引用。

### 3.6 搜索窗口

- `Search/SearchPanelView.swift` 与 `Search/SearchResultTableView.swift` 用同一设计系统翻新
  (控件布局、结果表样式、状态文案),不改变搜索行为。

### 3.7 测试

- `TreeExpansionStore` 纯逻辑单测:
  navigate(模拟)不清空、generation 变化清空、expandAncestors 展开祖先链。
- `CASCStorageService.entriesGeneration` 递增行为单测(无需真实存储,mock/直接构造)。
- 视觉部分无快照测试框架,人工截图对比验证(翻新前后各一组,明暗主题各一)。
- 全量回归:`xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test`
  (跑前确认 `/tmp/survey_enabled` 不存在)。

## 4. 明确不做(YAGNI)

- 不动模型查看器/BLP 查看器/安装清单/在线存储窗口。
- 不引入第三方 UI 库。
- 不改变搜索、导航、提取等行为语义。
- 不做 iOS/iPadOS 适配。

## 5. 风险与回退

- NSOutlineView 桥接重写是最大改动点:若大树性能回退,可退回扁平行模型但保留
  TreeExpansionStore 修复(收起 bug 修复与视觉翻新不依赖 NSOutlineView)。
- 全部改动集中在 `CascViewer/UI/` + `CASCStorageService` 加一个 generation 属性,
  与 `fix/m3a-animation-switch`、`feat/m3-material-layers` 分支的文件不重叠,可并行。

## 6. 实施偏差记录(终审留痕,2026-08-21)

实现过程中对本文档的有意缩水/修正,均已评审确认,留作 follow-up 候选:

- **3.1 节"工具栏并入系统 .toolbar"**:不可行 —— 主窗口是手工 NSWindow+NSHostingView,
  `.toolbar` 不会生成 NSToolbar。实际保持视图内工具栏行,仅做视觉翻新。
- **3.1 节"窗口标题显示当前存储名"**:未实现。窗口标题仍为静态 app 名
  (`CascViewerApp.swift` 的 `L("app_name")`)。follow-up 候选。
- **3.1 节分栏宽度持久化**:`@AppStorage("mainWindow.leftWidth"/"topRatio")` 随手写分栏移除,
  NavigationSplitView/VSplitView 不跨启动保存列宽(实施时误认为系统会 autosave)。
  用户可见的小回退,follow-up 决定是否恢复。
- **3.3 节"列头与排序指示器现代化"**:未做,列头保持系统默认。
- **3.4 节"详情面板卡片化"**:降级为 token 化(字体/间距/背景统一),未引入卡片视觉。
- 已验证无需处理:NSTableView 默认 `.lastColumnOnlyAutoresizingStyle` 使侧栏单列自动拉满
  (旧代码 180/100 宽度无需移植);TypeChip 垂直 padding 3→4pt;InfoRow label 失 medium 字重。

## 6b. 偏差记录(2026-08-21 晚,分栏比例修复)

- **3.1 节垂直分栏改用 VSplitView:实测不可行,回退为确定性手写分栏**。
  实证(诊断钩子 `--open-storage/--navigate/--dump-ui`,见下):
  1. SwiftUI VSplitView 初始分布把多余空间全分给最后一个子视图,`idealHeight` 不生效,
     文件列表被压到 `minHeight`(240pt),详情面板吃掉剩余全部空间;
  2. 之前的"GeometryReader 测量 + 防抖写 @AppStorage"持久化方案会把被压缩的尺寸写回配置,
     下次启动以它作 ideal 放大错误(用户机实测 previewHeight 被污染到 541pt),形成反馈循环;
  3. 改手桥 NSSplitView 后,底部面板被布局约束钉死在 minimumThickness,
     `setPosition`/用户拖动都会立即弹回(含 sizingOptions=[] 仍无效)。
  最终方案:`VerticalSplitView`(纯 SwiftUI,显式底部高度 + 1pt Divider 叠 9pt 透明拖拽热区),
  底部高度仅在拖动结束时写一次 `@AppStorage("mainWindow.detailHeight")`,默认 220pt。
  位置:`CascViewer/UI/MainWindow/VerticalSplitView.swift`。
- **诊断钩子(DEBUG only)**:`MainWindowView` 新增 `#if DEBUG` 的
  `--open-storage <路径>` / `--navigate <a,b,c>` / `--dump-ui <png>`
  启动参数,用于自动化复现真实存储下的布局问题(视图层级 dump + 窗口位图),Release 构建不含。
- 已知观感(非本次缺陷,macOS 26 系统行为):文件列表空白区域会绘制圆角交替行条纹
  (`usesAlternatingRowBackgroundColors` 的新样式),旧 UI 同样存在,未改动。

## 6c. 偏差记录(2026-08-22,侧栏系统组件整体弃用)

- **3.1 节 NavigationSplitView 侧栏:实测不可用,整体替换为自绘 `HorizontalSplitView`**。
  实证(AX 转储 + CGEvent 驱动 + screencapture/layer 位图逐帧对照):
  1. SwiftUI 自动装进标题栏的侧栏 toggle(AX 角色 AXToolbar>AXButton,desc="隐藏边栏")
     在折叠后从标题左侧跳到最右侧(x=571→x=1555);`.toolbar(removing: .sidebarToggle)`
     在 macOS 27 上无效(按钮依旧出现);
  2. 折叠/展开过渡会把文件列表渲染卡死在"半透明"(vibrant 文字变灰、列头近隐形,
     所有可见视图 alpha=1.0 无异常,但 app 自身 layer 渲染同样发灰;持续 60s+ 不自愈)。
     注:6b 中"半透明系 Xnip 采集 artifact"的判断被本次复现推翻,特此更正;
  3. 绑定 `columnVisibility` + `.animation(nil)` 可让我们的开关即时折叠且不再发灰,
     但系统 toggle 仍在;且从窗口左缘拖拽展开会在松手时被绑定值拽回折叠态(系统 bug)。
  最终方案:`HorizontalSplitView`(与 VerticalSplitView 同模式:显式宽度 180–400pt +
  折叠标志 + 1pt Divider 叠 9pt 透明热区),宽度仅在拖动结束时写一次
  `@AppStorage("mainWindow.sidebarWidth")`;折叠状态持久化于
  `@AppStorage("mainWindow.sidebarCollapsed")`;折叠/展开即时生效、无系统过渡。
  工具栏新增固定位置的侧栏开关(`sidebar.left` 图标,AX id `sidebarToggle`)。
  位置:`CascViewer/UI/MainWindow/HorizontalSplitView.swift`。
- **功能取舍**:折叠后不再支持"从窗口左缘拖出侧栏"(系统边缘手势随之移除),
  恢复侧栏一律走工具栏开关;分隔条不支持拖过最小宽度自动折叠。
- 验证:自动化验收四步(初始/折叠/展开/拖分隔条+80pt)全部渲染明亮无半透明,
  标题栏系统按钮在所有步骤均为 NONE,拖动后 sidebarWidth 落盘 338.5 正确。
