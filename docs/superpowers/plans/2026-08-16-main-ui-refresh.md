# 主窗口 + 搜索窗口 UI 翻新 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 翻新主文件浏览器窗口与搜索窗口的 UI,修复"导航导致目录树自动收起"的 bug,建立统一设计系统。

**Architecture:** 保留 NSTableView/懒渲染性能内核;目录树展开状态抽成独立的 `TreeExpansionStore`(仅存储重载时重置),树控件重写为 NSOutlineView 桥接;主窗口布局改 NavigationSplitView + VSplitView;新建 `DesignSystem.swift` 统一字体/颜色/间距。

**Tech Stack:** SwiftUI + AppKit (NSOutlineView/NSTableView 桥接),macOS 13+,XCTest。

**Spec:** `docs/superpowers/specs/2026-08-16-main-ui-refresh-design.md`

## Global Constraints

- 部署目标 macOS 13.0;不引入任何第三方依赖。
- 所有用户可见文案必须走现有 `L(_:_:)` 本地化;**本计划不新增任何文案 key**,只复用现有 key。
- 大存储(几十万~160 万文件)性能不得回退:树/列表保持懒渲染,不得引入全量扁平化渲染。
- 现有行为语义不变:排序、多选、双击导航、右键菜单、提取流程、远程文件红色标记(`AppSettings.showRemoteMarkers`)。
- 主窗口是手工创建的 `NSWindow + NSHostingView`(`CascViewer/App/CascViewerApp.swift:29-57`),**`.toolbar` 修饰符不会生成 NSToolbar** —— 工具栏保持视图内一行,只做视觉翻新(这是对 spec 3.1 节"并入系统 .toolbar"的修正)。
- `CascViewer.xcodeproj/project.pbxproj` **没有**文件系统同步组,新建 .swift 文件必须手工注册到 pbxproj(PBXBuildFile + PBXFileReference + group children + Sources phase 共 4 处,24 位十六进制 UUID)。
- 全量回归命令(后台跑,跑前必须确认 `/tmp/survey_enabled` 不存在):
  ```bash
  rm -f /tmp/survey_enabled
  set -o pipefail && xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test 2>&1 | grep -E "Test Suite '(All tests|CascViewerTests.xctest)'|Test Case.*failed|error:" | tail -8
  ```
- 单测筛选运行模式:`xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/<ClassName> 2>&1 | tail -20`

## 文件结构

- 新建 `CascViewer/UI/DesignSystem.swift` — 设计 token(字体/颜色/间距/圆角,SwiftUI + AppKit 双份)
- 新建 `CascViewer/UI/FileBrowser/TreeExpansionStore.swift` — 目录树展开状态(store)
- 新建 `CascViewerTests/TreeExpansionStoreTests.swift` — store 单测
- 修改 `CascViewer/Core/Services/CASCStorageService.swift` — 新增 `entriesGeneration`
- 修改 `CascViewerTests/IntegrationTests.swift` — generation 行为测试
- 重写 `CascViewer/UI/FileBrowser/FileTreeView.swift` — NSOutlineView 桥接 + store 接线
- 修改 `CascViewer/UI/MainWindow/MainWindowView.swift` — NavigationSplitView + VSplitView
- 修改 `CascViewer/UI/MainWindow/ToolbarView.swift` — 工具栏视觉翻新(SettingsView/ListFileButton 不动)
- 修改 `CascViewer/UI/FileBrowser/FileListView.swift` — 面包屑 + 列表 cell 视觉
- 修改 `CascViewer/UI/FileBrowser/FilePreviewPanel.swift` — 详情面板 token 化 + 等宽密钥
- 修改 `CascViewer/UI/MainWindow/StatusBarView.swift` — token 化
- 修改 `CascViewer/UI/Search/SearchPanelView.swift` / `SearchResultTableView.swift` — 搜索窗口 token 化
- 修改 `CascViewer.xcodeproj/project.pbxproj` — 注册 3 个新文件

---

### Task 1: TreeExpansionStore + 单测(TDD)

**Files:**
- Create: `CascViewer/UI/FileBrowser/TreeExpansionStore.swift`
- Create: `CascViewerTests/TreeExpansionStoreTests.swift`
- Modify: `CascViewer.xcodeproj/project.pbxproj`(注册两个新文件)

**Interfaces:**
- Consumes: 无(纯新逻辑)。
- Produces: `@MainActor final class TreeExpansionStore: ObservableObject`,提供
  `expandedPaths: Set<String>`(只读 @Published)、`isExpanded(_ path: String) -> Bool`、
  `toggle(_:)`、`expand(_:)`、`collapse(_:)`、`expandAncestors(of:)`、`reset()`。
  Task 2/5 的 FileTreeView 依赖这些签名。

- [ ] **Step 1: 写失败的测试**

创建 `CascViewerTests/TreeExpansionStoreTests.swift`:

```swift
import XCTest
@testable import CascViewer

@MainActor
final class TreeExpansionStoreTests: XCTestCase {

    func testToggleExpandsAndCollapses() {
        let store = TreeExpansionStore()
        XCTAssertFalse(store.isExpanded("mods"))
        store.toggle("mods")
        XCTAssertTrue(store.isExpanded("mods"))
        store.toggle("mods")
        XCTAssertFalse(store.isExpanded("mods"))
    }

    func testExpandAndCollapseAreIdempotent() {
        let store = TreeExpansionStore()
        store.expand("a")
        store.expand("a")
        XCTAssertEqual(store.expandedPaths, ["a"])
        store.collapse("a")
        store.collapse("a")
        XCTAssertTrue(store.expandedPaths.isEmpty)
    }

    func testExpandAncestorsExpandsWholeChain() {
        let store = TreeExpansionStore()
        store.expandAncestors(of: "mods/heroes.stormmod/base.stormassets")
        XCTAssertEqual(store.expandedPaths, [
            "mods",
            "mods/heroes.stormmod",
            "mods/heroes.stormmod/base.stormassets",
        ])
    }

    func testExpandAncestorsOfRootDoesNothing() {
        let store = TreeExpansionStore()
        store.expandAncestors(of: "")
        XCTAssertTrue(store.expandedPaths.isEmpty)
    }

    func testResetClearsExpansion() {
        let store = TreeExpansionStore()
        store.expandAncestors(of: "a/b/c")
        XCTAssertFalse(store.expandedPaths.isEmpty)
        store.reset()
        XCTAssertTrue(store.expandedPaths.isEmpty)
    }

    func testSiblingBranchesSurviveAncestorExpansion() {
        // 回归测试:展开某条路径的祖先链,不得清掉别处已展开的分支(旧的自动收起 bug)。
        let store = TreeExpansionStore()
        store.toggle("mods")
        store.toggle("mods/core.stormmod")
        store.expandAncestors(of: "campaigns/liberty.sc2campaign")
        XCTAssertTrue(store.isExpanded("mods"))
        XCTAssertTrue(store.isExpanded("mods/core.stormmod"))
        XCTAssertTrue(store.isExpanded("campaigns"))
        XCTAssertTrue(store.isExpanded("campaigns/liberty.sc2campaign"))
    }
}
```

- [ ] **Step 2: 注册两个新文件到 pbxproj 并运行,确认编译失败**

pbxproj 注册方法(对本计划全部新文件通用,以 `FileTreeView.swift` 现有条目为模板):

1. `PBXBuildFile` 段:仿 `74EE4289... /* FileTreeView.swift in Sources */` 新增一行,UUID 用 `openssl rand -hex 12` 生成(全大写)。
2. `PBXFileReference` 段:仿 `09735D48... /* FileTreeView.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = FileTreeView.swift; sourceTree = "<group>"; };` 新增,`path` 为新文件名。
3. group children:`TreeExpansionStore.swift` 加到 `UI/FileBrowser` 组的 children 列表;`TreeExpansionStoreTests.swift` 加到 `CascViewerTests` 组的 children 列表。
4. Sources phase:`TreeExpansionStore.swift in Sources` 加到 **CascViewer** target 的 Sources;`TreeExpansionStoreTests.swift in Sources` 加到 **CascViewerTests** target 的 Sources。

运行:
```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/TreeExpansionStoreTests 2>&1 | tail -5
```
预期:编译失败 `cannot find 'TreeExpansionStore' in scope`。

- [ ] **Step 3: 实现 TreeExpansionStore**

创建 `CascViewer/UI/FileBrowser/TreeExpansionStore.swift`:

```swift
import Foundation

/// 主窗口侧栏目录树的展开状态。
///
/// 展开状态在内存导航(CASCStorageService.navigate)下保持不变,
/// 只有在存储条目真正重载(entriesGeneration 变化)时由视图层调用 reset() 清空。
/// 这修复了"点开一个目录、另一个目录自动收起"的 bug。
@MainActor
final class TreeExpansionStore: ObservableObject {
    @Published private(set) var expandedPaths: Set<String> = []

    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func toggle(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
    }

    func expand(_ path: String) {
        expandedPaths.insert(path)
    }

    func collapse(_ path: String) {
        expandedPaths.remove(path)
    }

    /// 展开 path 本身及其全部祖先目录(复刻旧代码导航时自动展开祖先链的行为,
    /// 但不再清空其他分支)。
    func expandAncestors(of path: String) {
        var p = path
        while !p.isEmpty {
            expandedPaths.insert(p)
            p = (p as NSString).deletingLastPathComponent
        }
    }

    func reset() {
        expandedPaths.removeAll()
    }
}
```

- [ ] **Step 4: 运行测试,确认通过**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/TreeExpansionStoreTests 2>&1 | tail -5
```
预期:`Test Suite 'TreeExpansionStoreTests' passed`,6 个用例全过。

- [ ] **Step 5: 提交**

```bash
git add CascViewer/UI/FileBrowser/TreeExpansionStore.swift CascViewerTests/TreeExpansionStoreTests.swift CascViewer.xcodeproj/project.pbxproj
git commit -m "feat: add TreeExpansionStore for sidebar tree expansion state"
```

---

### Task 2: entriesGeneration + FileTreeView 接线(修复自动收起 bug)

**Files:**
- Modify: `CascViewer/Core/Services/CASCStorageService.swift`
- Modify: `CascViewerTests/IntegrationTests.swift`
- Modify: `CascViewer/UI/FileBrowser/FileTreeView.swift`(仅接线,此任务仍保留扁平 NSTableView)

**Interfaces:**
- Consumes: Task 1 的 `TreeExpansionStore`。
- Produces: `CASCStorageService.entriesGeneration: Int`(@Published,只读)、
  `CASCStorageService.noteEntriesReloaded()`。Task 5 的 `TreeOutlineView` 依赖 `entriesGeneration`。

- [ ] **Step 1: 写失败的测试**

在 `CascViewerTests/IntegrationTests.swift` 末尾(`testStorageCloseClearsState` 之后)追加:

```swift
    @MainActor
    func testEntriesGenerationIncrementsOnlyOnReload() {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)
        XCTAssertEqual(service.entriesGeneration, 0)
        service.noteEntriesReloaded()
        XCTAssertEqual(service.entriesGeneration, 1)

        // 内存导航不得递增 generation。
        service.navigate(to: "some/path")
        XCTAssertEqual(service.entriesGeneration, 1)
    }
```

运行:
```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/IntegrationTests/testEntriesGenerationIncrementsOnlyOnReload 2>&1 | tail -5
```
预期:编译失败 `value of type 'CASCStorageService' has no member 'entriesGeneration'`。

- [ ] **Step 2: 实现 entriesGeneration**

`CascViewer/Core/Services/CASCStorageService.swift` 三处修改:

(a) 在 `@Published var currentChildren: [DirectoryNode] = []`(约 line 139)之后插入:

```swift
    /// childrenByPath/entriesByPath 每次从原始条目重建(open/refresh)时递增。
    /// 内存导航(navigate)不会递增 —— 观察者用它区分"条目重载"(重置视图暂态)
    /// 与"导航"(保留目录树展开状态)。
    @Published private(set) var entriesGeneration: Int = 0
```

(b) 在 `navigate(to:)`(约 line 880)之前插入:

```swift
    /// 标记条目索引已重建。由 loadRootEntries 成功分支调用;internal 便于测试。
    func noteEntriesReloaded() {
        entriesGeneration &+= 1
    }
```

(c) `loadRootEntries()`(约 line 413)成功分支中,`self.entries = []`(约 line 460)之后插入一行:

```swift
            noteEntriesReloaded()
```

- [ ] **Step 3: 运行测试,确认通过**

同 Step 1 命令,预期 PASS。

- [ ] **Step 4: FileTreeView 接到 store(修 bug)**

`CascViewer/UI/FileBrowser/FileTreeView.swift` 六处修改:

(a) line 44 `@State private var expandedPaths: Set<String> = []` 替换为:

```swift
    @StateObject private var expansion = TreeExpansionStore()
```

(b) line 58 `let isExpanded = expandedPaths.contains(dir.path)` 替换为:

```swift
            let isExpanded = expansion.isExpanded(dir.path)
```

(c) `onToggleExpand` 闭包(lines 89-96)替换为:

```swift
                onToggleExpand: { path in
                    expansion.toggle(path)
                },
```

(d) lines 125-127 `.onChange(of: expandedPaths)` 替换为:

```swift
        .onChange(of: expansion.expandedPaths) { _ in
            rebuildDisplayRows()
        }
```

(e) lines 128-133 整个 `.onChange(of: storage.currentChildren)` 块(含 `expandedPaths.removeAll()`)替换为:

```swift
        .onChange(of: storage.entriesGeneration) { _ in
            // 条目真正重载(open/refresh)才重置展开状态;内存导航不会走到这里。
            expansion.reset()
            rebuildDisplayRows()
        }
```

(f) lines 134-150 `.onChange(of: storage.currentPath)` 块整体替换为:

```swift
        .onChange(of: storage.currentPath) { newPath in
            // 自动展开当前路径的祖先链,不清空别处已展开的分支。
            expansion.expandAncestors(of: newPath)
            rebuildDisplayRows()
        }
```

- [ ] **Step 5: 编译 + 相关测试全过**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/TreeExpansionStoreTests -only-testing:CascViewerTests/IntegrationTests 2>&1 | tail -5
```
预期:全部 PASS。

- [ ] **Step 6: 手工验证 bug 修复**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug build 2>&1 | tail -3
open build/Debug/CascViewer.app   # 若产物路径不同,用 xcodebuild -showBuildSettings | grep TARGET_BUILD_DIR 确认
```
打开一个真实存储,侧栏展开两个同级分支,点进其中一个导航 —— **另一个分支保持展开**(修复前会被收起)。

- [ ] **Step 7: 提交**

```bash
git add CascViewer/Core/Services/CASCStorageService.swift CascViewerTests/IntegrationTests.swift CascViewer/UI/FileBrowser/FileTreeView.swift
git commit -m "fix: stop sidebar tree from collapsing on navigation"
```

---

### Task 3: DesignSystem.swift(设计 token)

**Files:**
- Create: `CascViewer/UI/DesignSystem.swift`
- Modify: `CascViewer.xcodeproj/project.pbxproj`(注册新文件,方法同 Task 1 Step 2,加入 `UI` 组 + CascViewer target Sources)

**Interfaces:**
- Consumes: 无。
- Produces: `enum DS`,含 `DS.Spacing.{xs,sm,md,lg}`、`DS.Corner.{sm,md}`、
  `DS.Fonts.{sectionHeader,title,body,bodyMedium,caption,mono}`(SwiftUI `Font`)、
  `DS.Colors.{panelBackground,remoteFile,localYes,localNo,folderIcon,fileIcon,rowText,secondaryText}`(SwiftUI `Color`)、
  `DS.NSColors.{remoteFile,localYes,localNo,folderIcon,fileIcon,rowText,secondaryText}`(AppKit `NSColor`)。
  Task 4-8 全部依赖这些 token。

- [ ] **Step 1: 创建文件**

`CascViewer/UI/DesignSystem.swift`:

```swift
import SwiftUI
import AppKit

/// 主窗口与搜索窗口的统一设计 token。
/// 视图一律引用这里的常量,不再散落硬编码的字体大小/颜色/间距。
enum DS {

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    enum Corner {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
    }

    enum Fonts {
        /// 区块标题(如"目录"、"详情")
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
        /// 面板主标题(如详情面板文件名)
        static let title = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 12)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11)
        /// 等宽(编码密钥等)
        static let mono = Font.system(size: 11, design: .monospaced)
    }

    enum Colors {
        static let panelBackground = Color(NSColor.controlBackgroundColor)
        static let remoteFile = Color(NSColor.systemRed)
        static let localYes = Color(NSColor.systemGreen)
        static let localNo = Color(NSColor.systemOrange)
        static let folderIcon = Color(NSColor.controlAccentColor)
        static let fileIcon = Color(NSColor.secondaryLabelColor)
        static let rowText = Color(NSColor.labelColor)
        static let secondaryText = Color(NSColor.secondaryLabelColor)
    }

    /// AppKit cell 用的同一套颜色(NSTableView/NSOutlineView 桥接层)。
    enum NSColors {
        static let remoteFile = NSColor.systemRed
        static let localYes = NSColor.systemGreen
        static let localNo = NSColor.systemOrange
        static let folderIcon = NSColor.controlAccentColor
        static let fileIcon = NSColor.secondaryLabelColor
        static let rowText = NSColor.labelColor
        static let secondaryText = NSColor.secondaryLabelColor
    }

    /// AppKit cell 行文字号。
    static let rowFontSize: CGFloat = 12
}
```

- [ ] **Step 2: 注册 pbxproj + 编译验证**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug build 2>&1 | tail -3
```
预期:`BUILD SUCCEEDED`。

- [ ] **Step 3: 提交**

```bash
git add CascViewer/UI/DesignSystem.swift CascViewer.xcodeproj/project.pbxproj
git commit -m "feat: add design system tokens for main/search windows"
```

---

### Task 4: MainWindowView 布局重构 + ToolbarView 翻新

**Files:**
- Modify: `CascViewer/UI/MainWindow/MainWindowView.swift`
- Modify: `CascViewer/UI/MainWindow/ToolbarView.swift`
- Modify: `CascViewer/UI/FileBrowser/FileTreeView.swift`(仅移除容器背景色,适配侧栏材质)

**Interfaces:**
- Consumes: `DS.*`(Task 3);`FileTreeView`、`FileListView`、`FilePreviewPanel`、`StatusBarView`、`ToolbarView`、`LoadingOverlay` 现有视图。
- Produces: 无新接口(纯视图层)。

- [ ] **Step 1: 重写 MainWindowView**

`MainWindowView` 结构体(原 lines 61-193)整体替换为:

```swift
struct MainWindowView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ToolbarView()
                Divider()

                NavigationSplitView {
                    FileTreeView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
                } detail: {
                    VSplitView {
                        FileListView()
                            .frame(minHeight: 240)
                            .layoutPriority(1)
                        FilePreviewPanel()
                            .frame(minHeight: 140, idealHeight: 200)
                    }
                }

                Divider()
                StatusBarView()
            }

            if let storage = appState.currentStorage {
                LoadingOverlay(storage: storage, appState: appState)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(settings.theme.colorScheme)
        .alert(L("error"), isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button(L("ok")) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .environmentObject(appState)
    }
}
```

要点:删除 `@AppStorage("mainWindow.leftWidth")`、`@AppStorage("mainWindow.topRatio")` 及全部拖拽手势 state(hDragStartWidth 等)和 GeometryReader;分栏宽度交由系统。`LoadingOverlay` 原样保留(文件上半部分不动)。

- [ ] **Step 2: FileTreeView 容器背景移除(适配侧栏)**

`FileTreeView.swift` 两处:

(a) 空状态分支(原 line 37)删除 `.background(Color(NSColor.controlBackgroundColor))` 一行。
(b) `FileTreeContent` body(原 line 106)删除 `.background(Color(NSColor.controlBackgroundColor))` 一行。

(NavigationSplitView 侧栏自带材质背景;硬编码背景会盖住它。)

- [ ] **Step 3: ToolbarView 视觉翻新**

`ToolbarView` 的 `body`(原 lines 8-92)保持结构与全部行为闭包不变,只做以下样式替换:

(a) 外层 `HStack(spacing: 12)` → `HStack(spacing: DS.Spacing.lg)`,并在其上加 `.controlSize(.small)`。
(b) 搜索框胶囊:`.padding(.horizontal, 8)` → `.padding(.horizontal, DS.Spacing.md)`;`.padding(.vertical, 3)` → `.padding(.vertical, DS.Spacing.xs)`;`.cornerRadius(6)` → `.cornerRadius(DS.Corner.md)`;overlay 的 `RoundedRectangle(cornerRadius: 6)` → `RoundedRectangle(cornerRadius: DS.Corner.md)`。
(c) 刷新按钮 label `Text(L("refresh"))` 改为 `Label(L("refresh"), systemImage: "arrow.clockwise")`。
(d) 齿轮 `Image(systemName: "gear")` → `Image(systemName: "gearshape")`。
(e) 底部 `.padding(.horizontal)` + `.padding(.vertical, 8)` → `.padding(.horizontal, DS.Spacing.lg)` + `.padding(.vertical, DS.Spacing.md)`。

`SettingsView`、`ListFileButton`、`.sheet`、`.fileImporter` 全部不动。

- [ ] **Step 4: 编译 + 现有测试不回归**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/TreeExpansionStoreTests -only-testing:CascViewerTests/IntegrationTests 2>&1 | tail -5
```
预期:PASS(本任务无新测试,纯视图改动)。

- [ ] **Step 5: 手工验证**

build + open app:窗口出现系统风格分栏(侧栏半透明材质、系统分隔条可拖),无手写拖拽条;工具栏按钮变小号控件;明暗主题各看一眼。

- [ ] **Step 6: 提交**

```bash
git add CascViewer/UI/MainWindow/MainWindowView.swift CascViewer/UI/MainWindow/ToolbarView.swift CascViewer/UI/FileBrowser/FileTreeView.swift
git commit -m "refactor: NavigationSplitView layout and modernized toolbar"
```

---

### Task 5: 目录树重写为 NSOutlineView

**Files:**
- Rewrite: `CascViewer/UI/FileBrowser/FileTreeView.swift`(整体替换:删除 `TreeRow`、`TreeTableViewController`、`TreeTableView`)

**Interfaces:**
- Consumes: `TreeExpansionStore`(Task 1)、`CASCStorageService.entriesGeneration`(Task 2)、
  `DS.Fonts/DS.NSColors/DS.Spacing`(Task 3)、`storage.childrenByPath: [String: [DirectoryNode]]`、
  `DirectoryNode.{name,path,children,isLocal,hasChildDirectories}`、`storage.entriesUnder(path:)`、
  `storage.navigate(to:)`、`CASCExtractService`、`ExtractDialogView`、`ExtractionOverlay`。
- Produces: 无对外新接口(`FileTreeView` 视图签名不变)。

- [ ] **Step 1: 整体替换 FileTreeView.swift**

完整新内容:

```swift
import SwiftUI
import AppKit

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let storage = appState.currentStorage {
            FileTreeContent(storage: storage) { errorMessage in
                appState.errorMessage = errorMessage
            }
        } else {
            VStack(spacing: 0) {
                Text(L("directories"))
                    .font(DS.Fonts.sectionHeader)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                Divider()
                Text(L("open_storage_to_browse"))
                    .foregroundColor(.secondary)
                    .font(DS.Fonts.body)
                    .padding(.top, 20)
                Spacer()
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }
}

struct FileTreeContent: View {
    @ObservedObject var storage: CASCStorageService
    @StateObject private var expansion = TreeExpansionStore()
    @State private var extractEntries: [CASCFileEntry] = []
    @State private var showingExtractSheet = false
    @State private var activeExtractService: CASCExtractService? = nil
    var onError: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L("directories"))
                .font(DS.Fonts.sectionHeader)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)

            Divider()

            TreeOutlineView(
                generation: storage.entriesGeneration,
                childrenByPath: storage.childrenByPath,
                currentPath: storage.currentPath,
                expansion: expansion,
                onSelect: { path in
                    storage.navigate(to: path)
                },
                onExtract: { path in
                    extractEntries = storage.entriesUnder(path: path)
                    showingExtractSheet = !extractEntries.isEmpty
                }
            )

            Spacer()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .sheet(isPresented: $showingExtractSheet) {
            ExtractDialogView(entries: extractEntries) { destination, preserveStructure, overwriteExisting, openAfterExtract in
                Task {
                    await performExtraction(to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting, openAfterExtract: openAfterExtract)
                }
            }
        }
        .overlay {
            ExtractionOverlay(
                service: activeExtractService,
                titleKey: "extracting_files",
                width: 280,
                showPercentage: false
            )
        }
        .onChange(of: storage.entriesGeneration) { _ in
            // 条目真正重载(open/refresh)才重置展开状态;内存导航不会走到这里。
            expansion.reset()
        }
        .onChange(of: storage.currentPath) { newPath in
            // 自动展开当前路径的祖先链,不清空别处已展开的分支。
            expansion.expandAncestors(of: newPath)
        }
        .onDisappear {
            activeExtractService?.cancel()
        }
    }

    @MainActor
    private func performExtraction(to destination: URL, preserveStructure: Bool, overwriteExisting: Bool, openAfterExtract: Bool) async {
        let extractService = CASCExtractService(storage: storage.handle)
        activeExtractService = extractService
        let result = await extractService.extract(entries: extractEntries, to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting, openAfterExtract: openAfterExtract)
        activeExtractService = nil
        if result.wasCancelled {
            // Silently ignore cancelled extractions
        } else if result.failedFiles.isEmpty {
            if openAfterExtract {
                NSWorkspace.shared.open(destination)
            }
        } else {
            let failedList = result.failedFiles.prefix(10).map {
                let reason = $0.error.localizedDescription
                return "\($0.path)\n  ↳ \(reason)"
            }.joined(separator: "\n")
            let more = result.failedFiles.count > 10 ? "\n... \(result.failedFiles.count - 10) more" : ""
            let message = L("extract_partial", result.successCount, result.failedFiles.count) + "\n\n" + failedList + more
            onError(message)
        }
    }
}

// MARK: - NSOutlineView Bridge

@MainActor
final class TreeOutlineViewController: NSViewController {
    private var outlineView: NSOutlineView?
    private var scrollView: NSScrollView?

    /// 数据快照:仅含目录(children != nil),按父路径分组。
    private var dirCache: [String: [DirectoryNode]] = [:]
    private var nodeByPath: [String: DirectoryNode] = [:]
    private(set) var generation: Int = -1
    private var currentPath: String = ""
    /// 已同步到 outlineView 的展开集合,用于差量展开/收起。
    private var appliedExpansion: Set<String> = []

    var expansion: TreeExpansionStore?
    var onSelect: ((String) -> Void)?
    var onExtract: ((String) -> Void)?

    private var isProgrammaticSelection = false
    private var isSyncingExpansion = false

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.indentationPerLevel = 16
        outlineView.rowSizeStyle = .small
        outlineView.backgroundColor = .clear

        let col = NSTableColumn(identifier: .init("name"))
        col.title = L("name_column")
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col

        scrollView.documentView = outlineView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        outlineView.dataSource = self
        outlineView.delegate = self

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        self.scrollView = scrollView
        self.outlineView = outlineView
    }

    /// 条目重载(generation 变化)时调用:重建缓存、全量刷新、重新同步展开与选中。
    func reload(generation: Int, childrenByPath: [String: [DirectoryNode]], currentPath: String) {
        var cache: [String: [DirectoryNode]] = [:]
        var byPath: [String: DirectoryNode] = [:]
        for (path, children) in childrenByPath {
            let dirs = children.filter { $0.children != nil }
            cache[path] = dirs
            for dir in dirs {
                byPath[dir.path] = dir
            }
        }
        self.dirCache = cache
        self.nodeByPath = byPath
        self.generation = generation
        self.currentPath = currentPath
        self.appliedExpansion = []
        outlineView?.reloadData()
        applyExpansion()
        selectPath(currentPath)
    }

    /// 把 store 的展开状态差量同步到 outlineView(不触发通知回环)。
    func applyExpansion() {
        guard let outlineView = outlineView, let expansion = expansion else { return }
        let target = expansion.expandedPaths
        let old = appliedExpansion
        guard target != old else { return }
        isSyncingExpansion = true
        for path in old.subtracting(target) {
            if let node = nodeByPath[path] {
                outlineView.collapseItem(node)
            }
        }
        for path in target.subtracting(old) {
            if let node = nodeByPath[path] {
                outlineView.expandItem(node)
            }
        }
        appliedExpansion = target
        isSyncingExpansion = false
    }

    /// 按路径恢复选中(无该路径时清空选中)。
    func selectPath(_ path: String) {
        guard let outlineView = outlineView else { return }
        currentPath = path
        guard let node = nodeByPath[path] else {
            if outlineView.selectedRow >= 0 {
                isProgrammaticSelection = true
                outlineView.deselectAll(nil)
                isProgrammaticSelection = false
            }
            return
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        isProgrammaticSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isProgrammaticSelection = false
    }
}

extension TreeOutlineViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DirectoryNode else {
            return dirCache[""]?.count ?? 0
        }
        return dirCache[node.path]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? DirectoryNode else {
            return dirCache[""]![index]
        }
        return dirCache[node.path]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? DirectoryNode else { return false }
        return node.hasChildDirectories
    }
}

extension TreeOutlineViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DirectoryNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("treeCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            let newCell = NSTableCellView()
            newCell.identifier = identifier

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            newCell.imageView = icon
            newCell.addSubview(icon)

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = NSFont.systemFont(ofSize: DS.rowFontSize)
            newCell.textField = text
            newCell.addSubview(text)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Spacing.xs),
                text.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -DS.Spacing.xs)
            ])
            cell = newCell
        }

        cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = DS.NSColors.folderIcon
        cell.textField?.stringValue = node.name
        let remote = AppSettings.shared.showRemoteMarkers && !node.isLocal
        cell.textField?.textColor = remote ? DS.NSColors.remoteFile : DS.NSColors.rowText
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 24
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection, !isSyncingExpansion else { return }
        guard let outlineView = outlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? DirectoryNode else { return }
        onSelect?(node.path)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DirectoryNode else { return }
        appliedExpansion.insert(node.path)
        if !isSyncingExpansion {
            expansion?.expand(node.path)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DirectoryNode else { return }
        appliedExpansion.remove(node.path)
        if !isSyncingExpansion {
            expansion?.collapse(node.path)
        }
    }
}

extension TreeOutlineViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outlineView = outlineView else { return }
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? DirectoryNode else { return }

        let path = node.path
        let openItem = NSMenuItem(title: L("open"), action: #selector(handleMenuOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = path
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let extractItem = NSMenuItem(title: L("extract_all"), action: #selector(handleMenuExtract(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = path
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        let copyPathItem = NSMenuItem(title: L("copy_path"), action: #selector(handleMenuCopyPath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.representedObject = path
        menu.addItem(copyPathItem)
    }

    @objc private func handleMenuOpen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onSelect?(path)
    }

    @objc private func handleMenuExtract(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onExtract?(path)
    }

    @objc private func handleMenuCopyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

struct TreeOutlineView: NSViewControllerRepresentable {
    let generation: Int
    let childrenByPath: [String: [DirectoryNode]]
    let currentPath: String
    let expansion: TreeExpansionStore
    var onSelect: ((String) -> Void)?
    var onExtract: ((String) -> Void)?

    func makeNSViewController(context: Context) -> TreeOutlineViewController {
        let vc = TreeOutlineViewController()
        _ = vc.view
        vc.expansion = expansion
        vc.onSelect = onSelect
        vc.onExtract = onExtract
        vc.reload(generation: generation, childrenByPath: childrenByPath, currentPath: currentPath)
        return vc
    }

    func updateNSViewController(_ vc: TreeOutlineViewController, context: Context) {
        guard vc.isViewLoaded else { return }
        vc.expansion = expansion
        vc.onSelect = onSelect
        vc.onExtract = onExtract
        if vc.generation != generation {
            vc.reload(generation: generation, childrenByPath: childrenByPath, currentPath: currentPath)
        } else {
            vc.applyExpansion()
            vc.selectPath(currentPath)
        }
    }
}
```

注意:右键菜单中目录节点的"提取"标题固定用 `L("extract_all")`(树里只有目录节点,旧代码的三元判断在树场景下恒为目录分支)。

- [ ] **Step 2: 编译 + 全部已有测试不回归**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/TreeExpansionStoreTests -only-testing:CascViewerTests/IntegrationTests 2>&1 | tail -5
```
预期:PASS。

- [ ] **Step 3: 手工验证**

build + open app,逐项过:
- 展开/收起有系统原生三角与动画;键盘左右方向键可展开/收起。
- 展开两个同级分支,导航进其一,另一分支保持展开(Task 2 的修复仍生效)。
- 文件列表双击目录、面包屑跳转后,树中祖先链自动展开且选中当前目录。
- 右键菜单:打开 / 全部提取 / 复制路径均可用。
- 打开 30 万+ 文件的存储(如 HotS),滚动与展开不卡。

- [ ] **Step 4: 提交**

```bash
git add CascViewer/UI/FileBrowser/FileTreeView.swift
git commit -m "refactor: rewrite sidebar tree as NSOutlineView"
```

---

### Task 6: 文件列表视觉翻新(面包屑 + cell)

**Files:**
- Modify: `CascViewer/UI/FileBrowser/FileListView.swift`

**Interfaces:**
- Consumes: `DS.*`(Task 3)。
- Produces: 无新接口。

- [ ] **Step 1: 重写 pathBar(面包屑)**

`FileListContent.pathBar`(原 lines 229-270)整体替换为:

```swift
    @ViewBuilder
    private var pathBar: some View {
        HStack(spacing: DS.Spacing.xs) {
            Button(action: { storage.navigate(to: "") }) {
                Image(systemName: "house")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(L("root"))

            if !storage.currentPath.isEmpty {
                Button(action: {
                    let path = storage.currentPath
                    if let lastSlash = path.lastIndex(of: "/") {
                        storage.navigate(to: String(path[..<lastSlash]))
                    } else {
                        storage.navigate(to: "")
                    }
                }) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(L("parent_directory"))

                let components = storage.currentPath.split(separator: "/", omittingEmptySubsequences: true)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(DS.Fonts.caption)
                        .foregroundColor(.secondary)
                    Button(action: {
                        storage.navigate(to: components[0...index].joined(separator: "/"))
                    }) {
                        Text(String(component))
                            .font(DS.Fonts.bodyMedium)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            Spacer()
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .transaction { $0.animation = nil }
    }
```

(移除旧的硬编码背景色与 › 文本分隔符;导航行为不变。)

- [ ] **Step 2: cell 字体与颜色 token 化**

`FileTableViewController.tableView(_:viewFor:row:)`(原 lines 610-672)两处修改:

(a) cell 创建块中,`cell?.textField = text` 之前插入一行:

```swift
            text.font = NSFont.systemFont(ofSize: DS.rowFontSize)
```

(b) `switch colID` 块整体替换为:

```swift
        switch colID {
        case "name":
            cell?.textField?.stringValue = item.name
            cell?.textField?.textColor = DS.NSColors.rowText
            cell?.imageView?.image = NSImage(systemSymbolName: item.iconName, accessibilityDescription: nil)
            cell?.imageView?.contentTintColor = item.children != nil ? DS.NSColors.folderIcon : DS.NSColors.fileIcon
            cell?.imageView?.isHidden = false
            // 远程文件红色标记(AppSettings.showRemoteMarkers)
            if AppSettings.shared.showRemoteMarkers && !item.isLocal {
                cell?.textField?.textColor = DS.NSColors.remoteFile
            }
        case "path":
            cell?.textField?.stringValue = item.path
            cell?.textField?.textColor = DS.NSColors.secondaryText
            cell?.imageView?.isHidden = true
        case "size":
            cell?.textField?.stringValue = item.formattedSize
            cell?.textField?.textColor = DS.NSColors.secondaryText
            cell?.imageView?.isHidden = true
        case "type":
            cell?.textField?.stringValue = item.children != nil ? L("folder") : L("file")
            cell?.textField?.textColor = DS.NSColors.secondaryText
            cell?.imageView?.isHidden = true
        case "local":
            cell?.textField?.stringValue = item.isLocal ? L("local_yes") : L("local_no")
            cell?.textField?.textColor = item.isLocal ? DS.NSColors.localYes : DS.NSColors.localNo
            cell?.imageView?.isHidden = true
        default:
            break
        }
```

- [ ] **Step 3: 编译 + 手工验证**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug build 2>&1 | tail -3
```
open app:面包屑为系统小号无边框按钮 + chevron 分隔;列表文字 12pt,次级列灰色;排序/多选/双击/右键菜单/路径列自动隐藏行为不变。

- [ ] **Step 4: 提交**

```bash
git add CascViewer/UI/FileBrowser/FileListView.swift
git commit -m "refactor: modernize breadcrumb bar and file list cells"
```

---

### Task 7: 详情面板 + 状态栏 token 化

**Files:**
- Modify: `CascViewer/UI/FileBrowser/FilePreviewPanel.swift`
- Modify: `CascViewer/UI/MainWindow/StatusBarView.swift`

**Interfaces:**
- Consumes: `DS.*`(Task 3)。
- Produces: `InfoRow` 新增 `monospaced: Bool = false` 参数(仅本文件内使用)。

- [ ] **Step 1: FilePreviewPanel 修改**

`CascViewer/UI/FileBrowser/FilePreviewPanel.swift` 七处:

(a) 标题 `Text(L("details_panel"))` 的 `.font(.system(size: 11, weight: .semibold))` → `.font(DS.Fonts.sectionHeader)`。
(b) 文件名 `Text(entry.name)` 的 `.font(.system(size: 13, weight: .semibold))` → `.font(DS.Fonts.title)`。
(c) 类型行 `Text(entry.isDirectory ? L("folder") : L("file"))` 的 `.font(.system(size: 11))` → `.font(DS.Fonts.caption)`。
(d) 编码密钥行(原 line 57)替换为:

```swift
                    InfoRow(label: L("encoding_key_label"), value: entry.encodingKey, monospaced: true)
```

(e) 空状态 `Text(L("select_file_for_details"))` 的 `.font(.system(size: 12))` → `.font(DS.Fonts.body)`。
(f) 内容 `.padding(12)` → `.padding(DS.Spacing.lg)`。
(g) `InfoRow`(原 lines 226-243)整体替换为:

```swift
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Text(label + ":")
                .font(DS.Fonts.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? DS.Fonts.mono : DS.Fonts.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
```

(h) 标题栏 `.background(Color(NSColor.controlBackgroundColor))`(原 line 30)与面板整体 `.background(Color(NSColor.controlBackgroundColor))`(原 line 121)均 → `.background(DS.Colors.panelBackground)`。

打开/提取逻辑(`openModelFile`/`openImageFile` 等)一律不动。

- [ ] **Step 2: StatusBarView 修改**

`CascViewer/UI/MainWindow/StatusBarView.swift`:全部 `.font(.caption)` → `.font(DS.Fonts.caption)`;两处 `.padding(.horizontal, 12)` → `.padding(.horizontal, DS.Spacing.lg)`;两处 `.padding(.vertical, 4)` → `.padding(.vertical, DS.Spacing.xs)`;两处 `.background(Color(NSColor.controlBackgroundColor))` → `.background(DS.Colors.panelBackground)`。结构与文案 key 不变。

- [ ] **Step 3: 编译 + 手工验证**

build + open app:详情面板编码密钥为等宽字体;选中图片/模型文件时按钮正常;状态栏内容完整(当前目录数/总数/选中项/存储信息)。

- [ ] **Step 4: 提交**

```bash
git add CascViewer/UI/FileBrowser/FilePreviewPanel.swift CascViewer/UI/MainWindow/StatusBarView.swift
git commit -m "refactor: apply design tokens to preview panel and status bar"
```

---

### Task 8: 搜索窗口翻新

**Files:**
- Modify: `CascViewer/UI/Search/SearchPanelView.swift`
- Modify: `CascViewer/UI/Search/SearchResultTableView.swift`

**Interfaces:**
- Consumes: `DS.*`(Task 3)。
- Produces: 无新接口。

- [ ] **Step 1: SearchPanelView token 化**

`CascViewer/UI/Search/SearchPanelView.swift` 六处:

(a) 顶部搜索框胶囊(原 lines 61-68):`.padding(.horizontal, 8)` → `.padding(.horizontal, DS.Spacing.md)`;`.padding(.vertical, 4)` → `.padding(.vertical, DS.Spacing.xs)`;`.cornerRadius(6)` → `.cornerRadius(DS.Corner.md)`;`RoundedRectangle(cornerRadius: 6)` → `RoundedRectangle(cornerRadius: DS.Corner.md)`。
(b) 结果头部 HStack 的 `.padding(.horizontal, 12)` → `.padding(.horizontal, DS.Spacing.lg)`;`.padding(.vertical, 6)` → `.padding(.vertical, DS.Spacing.sm)`。
(c) `TypeChip`(原 lines 425-443)body 替换为:

```swift
    var body: some View {
        Button(action: action) {
            Text(type)
                .font(DS.Fonts.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .cornerRadius(DS.Corner.sm)
        }
        .buttonStyle(.plain)
    }
```

(d) `TagCheckbox`(原 lines 447-469)中:图标 `.font(.system(size: 12))` → `.font(DS.Fonts.body)`;文字 `.font(.caption)` → `.font(DS.Fonts.caption)`。
(e) 自定义扩展名 TextField 的 `.font(.system(size: 11))` → `.font(DS.Fonts.caption)`。
(f) 空态图标 `.font(.system(size: 36))` 保持不变;`magnifyingglass.circle`/`magnifyingglass` 与文案不变。

搜索/排序/过滤/提取行为与 `onChange` 逻辑一律不动。

- [ ] **Step 2: SearchResultTableView cell token 化**

`SearchResultTableViewController.tableView(_:viewFor:row:)`(原 lines 201-259)两处:

(a) cell 创建块中,`cell?.textField = text` 之前插入一行:

```swift
            text.font = NSFont.systemFont(ofSize: DS.rowFontSize)
```

(b) `switch colID` 块整体替换为:

```swift
        switch colID {
        case "name":
            cell?.textField?.stringValue = match.entry.name
            cell?.textField?.textColor = DS.NSColors.rowText
            let iconName = match.entry.isDirectory ? "folder" : "doc"
            cell?.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            cell?.imageView?.contentTintColor = match.entry.isDirectory ? DS.NSColors.folderIcon : DS.NSColors.fileIcon
            cell?.imageView?.isHidden = false
            if AppSettings.shared.showRemoteMarkers && !match.entry.isLocal {
                cell?.textField?.textColor = DS.NSColors.remoteFile
            }
        case "path":
            cell?.textField?.stringValue = match.entry.normalizedPath
            cell?.textField?.textColor = DS.NSColors.secondaryText
            cell?.imageView?.isHidden = true
        case "size":
            cell?.textField?.stringValue = match.entry.formattedSize
            cell?.textField?.textColor = DS.NSColors.secondaryText
            cell?.imageView?.isHidden = true
        default:
            break
        }
```

- [ ] **Step 3: 编译 + 手工验证**

build + open app,打开高级搜索窗口:执行一次文件名搜索,结果表正常;双击结果跳转主窗口定位仍正常;右键菜单(去位置/打开/提取/复制路径)正常。

- [ ] **Step 4: 提交**

```bash
git add CascViewer/UI/Search/SearchPanelView.swift CascViewer/UI/Search/SearchResultTableView.swift
git commit -m "refactor: apply design tokens to search window"
```

---

### Task 9: 全量回归 + 视觉验收

**Files:**
- Modify: 无(仅验证;发现问题回到对应任务修)。

**Interfaces:**
- Consumes: 全部前序任务。
- Produces: 无。

- [ ] **Step 1: 全量回归(后台跑)**

```bash
rm -f /tmp/survey_enabled
set -o pipefail && xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test 2>&1 | grep -E "Test Suite '(All tests|CascViewerTests.xctest)'|Test Case.*failed|error:" | tail -8
```
预期:`Test Suite 'All tests' passed`,无 failed 用例、无 error。

- [ ] **Step 2: 手工验收清单**

build + open app,两个真实存储(SC2 `/Users/ales/Desktop/StarCraft II` 与 HotS `/Applications/Heroes of the Storm`)各过一遍:

1. 侧栏展开多个分支并随意导航,分支互不收起;刷新存储后展开状态重置(预期行为)。
2. 双击列表目录、面包屑跳转、home/上级按钮,树同步选中并自动展开祖先。
3. 列表排序(点各列头)、多选、右键提取、详情面板、状态栏。
4. 工具栏:打开存储菜单、搜索框回车弹出搜索窗、刷新、安装文件列表、设置。
5. 搜索窗:四种模式 UI 正常,结果跳转主窗口。
6. 明暗主题切换(设置里),两个窗口都无配色违和。
7. 在线存储若可测:远程文件红色标记仍生效。
8. 与修复前截图对比(用户人工核对),确认"老旧感"消除。

- [ ] **Step 3: 收官提交(若有收尾修正)**

```bash
git status   # 确认工作区干净或提交收尾修正
git log --oneline main..HEAD   # 应见 8 个左右的任务提交
```
