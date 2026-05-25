import SwiftUI
import CascBridge

struct ToolbarView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingOpenPanel = false
    @State private var showingSettings = false
    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button(L("open_local_storage")) {
                    showingOpenPanel = true
                }
                Button(L("open_online_storage")) {
                    OnlineStorageWindowController.show(appState: appState)
                }
            } label: {
                Text(L("open_storage"))
            }
            .menuStyle(.borderedButton)
            .fixedSize()

            if appState.currentStorage != nil {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField(L("search_placeholder"), text: $appState.searchQuery)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .onSubmit {
                            if !appState.searchQuery.isEmpty {
                                SearchWindowController.show(appState: appState)
                            }
                        }
                    if !appState.searchQuery.isEmpty {
                        Button(action: { appState.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Button(L("refresh")) {
                    guard let storage = appState.currentStorage else { return }
                    Task {
                        // Rebuild the children map to pick up any external changes
                        await storage.refreshCurrentStorage()
                    }
                }

                Button(L("advanced_search")) {
                    SearchWindowController.show(appState: appState)
                }
                .fixedSize()

                if let storage = appState.currentStorage {
                    ListFileButton(storage: storage)
                }

                Button(action: {
                    appState.showInstallManifestWindow()
                }) {
                    Text(L("install_manifest"))
                }
                .fixedSize()
            }

            Spacer()

            Button(action: {
                showingSettings = true
            }) {
                Image(systemName: "gear")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .frame(minWidth: 640, minHeight: 800)
        }
        .fileImporter(
            isPresented: $showingOpenPanel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            Task { @MainActor in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        appState.openStorageTask?.cancel()
                        appState.openStorageTask = Task {
                            let didStartAccessing = url.startAccessingSecurityScopedResource()
                            defer {
                                if didStartAccessing {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }
                            let storage = CascBridge.CascStorageHandle.createLocal()
                            let service = CASCStorageService(storage: storage)
                            appState.currentStorage?.close()
                            appState.currentStorage = service
                            await service.openLocal(path: url.path)
                            if service.error != nil {
                                appState.errorMessage = service.error?.localizedDescription
                            }
                            appState.openStorageTask = nil
                        }
                    }
                case .failure(let error):
                    appState.errorMessage = error.localizedDescription
                }
            }
        }

    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingClearCacheAlert = false
    @State private var cacheClearedSize = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(L("settings_title"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Content
            Form {
                Section(header: Text(L("settings_storage")).font(.headline)) {
                    Toggle(L("cdn_download"), isOn: $settings.cdnDownloadEnabled)
                        .help(L("cdn_download_help"))

                    HStack {
                        Text(L("cdn_cache_path"))
                        Spacer()
                        Text(settings.cdnCachePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)
                        Button(L("browse")) {
                            chooseCachePath()
                        }
                    }
                    .disabled(!settings.cdnDownloadEnabled)
                }

                Section(header: Text(L("settings_extraction")).font(.headline)) {
                    HStack {
                        Text(L("default_path"))
                        Spacer()
                        Text(settings.defaultExtractPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)
                        Button(L("browse")) {
                            chooseDefaultExtractPath()
                        }
                    }

                    Toggle(L("keep_structure"), isOn: $settings.preserveStructure)
                    Toggle(L("overwrite_existing"), isOn: $settings.overwriteExisting)
                    Toggle(L("open_after_extract"), isOn: $settings.openAfterExtract)
                }

                Section(header: Text(L("settings_display")).font(.headline)) {
                    Picker(L("language"), selection: $settings.language) {
                        ForEach(AppSettings.shared.availableLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }

                    Toggle(L("show_remote_markers"), isOn: $settings.showRemoteMarkers)
                        .help(L("show_remote_markers_help"))

                    Toggle(L("use_builtin_image_viewer"), isOn: $settings.useBuiltInImageViewer)
                        .help(L("use_builtin_image_viewer_help"))

                    Picker(L("theme"), selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(L(theme.localizationKey)).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text(L("settings_cache")).font(.headline)) {
                    Button(L("clear_cache")) {
                        clearCache()
                    }
                    .foregroundColor(.red)
                }

                Section(header: Text(L("settings_about")).font(.headline)) {
                    HStack {
                        Text(L("app_name"))
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(L("casc_lib"))
                        Spacer()
                        Text("9fb2d38")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Bottom buttons
            HStack {
                Button(L("reset_defaults")) {
                    settings.resetToDefaults()
                }
                Spacer()
                Button(L("done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button("") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 640, height: 800)
        .alert(L("cache_cleared_title"), isPresented: $showingClearCacheAlert) {
            Button(L("ok"), role: .cancel) {}
        } message: {
            Text(cacheClearedSize)
        }
    }

    private func chooseDefaultExtractPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("choose")

        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url {
                Task { @MainActor in
                    self.settings.defaultExtractPath = url.path
                }
            }
        }
    }

    private func chooseCachePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("choose")

        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url {
                Task { @MainActor in
                    self.settings.cdnCachePath = url.path
                }
            }
        }
    }

    private func clearCache() {
        settings.clearCache()
        cacheClearedSize = L("cache_cleared_message")
        showingClearCacheAlert = true
    }
}

struct ListFileButton: View {
    @ObservedObject var storage: CASCStorageService
    @State private var hasAutoShown = false
    @State private var pendingPromptTask: Task<Void, Never>? = nil

    var body: some View {
        if storage.needsListFile {
            Button {
                showPanel()
            } label: {
                Label(L("load_listfile"), systemImage: "doc.text")
            }
            .fixedSize()
            .onAppear {
                if storage.needsListFile && !hasAutoShown {
                    hasAutoShown = true
                    showPrompt()
                }
            }
            .onReceive(storage.$needsListFile) { needsListFile in
                if needsListFile && !hasAutoShown {
                    pendingPromptTask?.cancel()
                    pendingPromptTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if !hasAutoShown, !Task.isCancelled {
                            hasAutoShown = true
                            showPrompt()
                        }
                    }
                }
            }
            .onDisappear {
                pendingPromptTask?.cancel()
            }
        }
    }

    private func showPrompt() {
        let alert = NSAlert()
        alert.messageText = L("listfile_prompt_title")
        alert.informativeText = L("listfile_prompt_message")
        alert.alertStyle = .informational
        alert.icon = NSImage(size: NSSize(width: 1, height: 1))
        alert.addButton(withTitle: L("listfile_prompt_ok"))
        alert.addButton(withTitle: L("listfile_prompt_cancel"))
        
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        self.showPanel()
                    }
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                showPanel()
            }
        }
    }

    private func showPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.prompt = L("load_listfile")
        
        let completion: (NSApplication.ModalResponse) -> Void = { result in
            if result == .OK, let url = panel.url {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                Task { @MainActor in
                    storage.listFilePath = url.path
                    var handle = storage.handle
                    handle.setListFilePath(std.string(url.path))
                    await storage.refreshCurrentStorage()
                    storage.needsListFile = false
                }
            }
        }
        
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
