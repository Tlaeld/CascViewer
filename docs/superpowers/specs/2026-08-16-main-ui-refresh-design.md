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
