import SwiftUI
#if DEBUG
import CascBridge
#endif

struct LoadingOverlay: View {
    @ObservedObject var storage: CASCStorageService
    @ObservedObject var appState: AppState

    var body: some View {
        if storage.isLoading {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    if storage.loadProgress > 0 {
                        ProgressView(value: storage.loadProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)
                    } else {
                        ProgressView()
                            .scaleEffect(1.2)
                    }

                    Text(L("loading_storage"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)

                    if !storage.loadProgressMessage.isEmpty {
                        Text(storage.loadProgressMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if storage.loadProgress > 0 {
                        Text("\(Int(storage.loadProgress * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Button(L("cancel")) {
                        appState.openStorageTask?.cancel()
                        appState.openStorageTask = nil
                        // Immediately hide the loading UI even though the underlying
                        // synchronous C++ open() may still be running in the detached task.
                        storage.isLoading = false
                        storage.loadProgress = 0
                        storage.loadProgressMessage = ""
                    }
                    .buttonStyle(.bordered)
                }
                .padding(24)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 8)
                .frame(minWidth: 280, maxWidth: 360)
            }
        }
    }
}

/// 把 SwiftUI 计算出的标题同步到宿主 NSWindow(经 view.window 即时解析,归属正确窗口)。
private struct WindowTitleApplier: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window, window.title != title else { return }
        window.title = title
    }
}

struct MainWindowView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var settings = AppSettings.shared

    // 侧栏显隐/宽度都由 HorizontalSplitView 自绘接管(系统 NavigationSplitView 的
    // toggle 按钮位置乱跳、折叠过渡会把列表渲染卡死在半透明,详见 HorizontalSplitView 注释)。
    @AppStorage("mainWindow.sidebarCollapsed") private var sidebarCollapsed: Bool = false

    private var windowTitle: String {
        let base = L("app_name")
        guard let name = appState.currentStorage?.storageDisplayName, !name.isEmpty else {
            return base
        }
        return "\(base) — \(name)"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ToolbarView(sidebarCollapsed: $sidebarCollapsed)
                Divider()

                HorizontalSplitView(storageKey: "mainWindow.sidebarWidth",
                                    collapsed: $sidebarCollapsed) {
                    FileTreeView()
                } detail: {
                    VerticalSplitView(storageKey: "mainWindow.detailHeight") {
                        FileListView()
                    } bottom: {
                        FilePreviewPanel()
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
        .background(WindowTitleApplier(title: windowTitle))
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
#if DEBUG
        .task { runDebugAutomation() }
#endif
    }

#if DEBUG
    /// DEBUG 专用的自动化诊断钩子(发布构建不含此代码):
    /// `--open-storage <本地路径>` 启动后自动打开本地存储;
    /// `--navigate <a,b,c>` 打开后按逗号分隔逐级导航(模拟逐层点击);
    /// `--dump-ui <png路径>` 导航完成后把视图层级打到 stdout,并把窗口位图存到指定路径。
    private func runDebugAutomation() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--open-storage"), args.count > idx + 1,
              appState.currentStorage == nil else { return }
        let storagePath = args[idx + 1]
        var navigateSteps: [String] = []
        if let nIdx = args.firstIndex(of: "--navigate"), args.count > nIdx + 1 {
            navigateSteps = args[nIdx + 1].split(separator: ",").map(String.init)
        }
        var dumpPath: String?
        if let dIdx = args.firstIndex(of: "--dump-ui"), args.count > dIdx + 1 {
            dumpPath = args[dIdx + 1]
        }
        // --dump-repeat <n>:启动后每 2 秒转储一次、共 n 次(文件名加序号),
        // 用于在外部脚本驱动 UI 交互的过程中抓多个时间点的视图状态。
        var dumpRepeat = 0
        if let rIdx = args.firstIndex(of: "--dump-repeat"), args.count > rIdx + 1 {
            dumpRepeat = Int(args[rIdx + 1]) ?? 0
        }
        if dumpRepeat > 0, let repeatPath = dumpPath {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for i in 1...dumpRepeat {
                    dumpUI(to: "\(repeatPath)-\(i)")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        appState.openStorageTask?.cancel()
        appState.openStorageTask = Task { @MainActor in
            let service = CASCStorageService(storage: CascBridge.CascStorageHandle.createLocal())
            appState.currentStorage?.close()
            appState.currentStorage = service
            await service.openLocal(path: storagePath)
            if let error = service.error {
                appState.errorMessage = error.localizedDescription
                appState.openStorageTask = nil
                return
            }
            for step in navigateSteps {
                service.navigate(to: step)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            appState.openStorageTask = nil
            if let dumpPath {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dumpUI(to: dumpPath)
            }
        }
    }

    private func dumpUI(to pngPath: String) {
        guard let window = NSApp.windows.first(where: { $0.frameAutosaveName == "CascViewerMainWindow" }),
              let content = window.contentView else {
            print("=== UI DUMP: main window not found ===")
            return
        }
        var lines: [String] = ["window frame=\(window.frame)"]
        func walk(_ view: NSView, _ depth: Int) {
            let f = view.frame
            var extra = ""
            if let tv = view as? NSTableView {
                extra += " rows=\(tv.numberOfRows) rowHeight=\(tv.rowHeight) headerFrame=\(String(describing: tv.headerView?.frame)) cornerView=\(String(describing: tv.cornerView))"
            }
            if let ov = view as? NSOutlineView {
                extra += " rows=\(ov.numberOfRows) rowHeight=\(ov.rowHeight)"
            }
            if view.isHidden { extra += " HIDDEN" }
            if view.alphaValue < 1 { extra += " alpha=\(view.alphaValue)" }
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(f)\(extra)")
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        walk(content, 0)
        let dump = lines.joined(separator: "\n")
        try? (dump + "\n").write(toFile: pngPath + ".txt", atomically: true, encoding: .utf8)
        print("=== UI DUMP ===\n" + dump + "\n=== END DUMP ===")
        fflush(stdout)

        // 位图:经 layer 树渲染,覆盖 SwiftUI/hosting 内容。
        let scale: CGFloat = window.backingScaleFactor
        let size = content.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = ctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        // layer 树渲染按 AppKit 左下原点输出,翻转回屏幕朝向。
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        if let layer = content.layer {
            layer.render(in: cg)
        } else {
            content.displayIgnoringOpacity(content.bounds, in: ctx)
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: pngPath))
            print("=== UI DUMP: bitmap written to \(pngPath) ===")
        }
    }
#endif
}
