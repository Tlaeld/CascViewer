import SwiftUI

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

/// 把 SwiftUI 计算出的标题同步到宿主的纯手工 NSWindow(多窗口各自独立)。
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

    // 分栏宽度/高度持久化(NavigationSplitView/VSplitView 自身不 autosave)
    @AppStorage("mainWindow.sidebarWidth") private var sidebarWidth: Double = 240
    @AppStorage("mainWindow.previewHeight") private var previewHeight: Double = 200
    @State private var sidebarPersistTask: Task<Void, Never>?
    @State private var previewPersistTask: Task<Void, Never>?

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
                ToolbarView()
                Divider()

                NavigationSplitView {
                    FileTreeView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: CGFloat(sidebarWidth), max: 400)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onChange(of: geo.size.width) { newWidth in
                                        scheduleSidebarPersist(newWidth)
                                    }
                            }
                        )
                } detail: {
                    VSplitView {
                        FileListView()
                            .frame(minHeight: 240)
                            .layoutPriority(1)
                        FilePreviewPanel()
                            .frame(minHeight: 140, idealHeight: CGFloat(previewHeight))
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onChange(of: geo.size.height) { newHeight in
                                            schedulePreviewPersist(newHeight)
                                        }
                                }
                            )
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
    }

    /// 拖动停止 0.3s 后才落盘,避免拖动过程中逐帧写 UserDefaults。
    private func scheduleSidebarPersist(_ width: CGFloat) {
        let value = Double(width)
        guard abs(value - sidebarWidth) > 0.5 else { return }
        sidebarPersistTask?.cancel()
        sidebarPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            sidebarWidth = value
        }
    }

    private func schedulePreviewPersist(_ height: CGFloat) {
        let value = Double(height)
        guard abs(value - previewHeight) > 0.5 else { return }
        previewPersistTask?.cancel()
        previewPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            previewHeight = value
        }
    }
}
