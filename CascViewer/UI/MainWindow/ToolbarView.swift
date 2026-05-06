import SwiftUI
import CascBridge

struct ToolbarView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingOpenPanel = false
    @State private var showingSettings = false
    @State private var showingSearchPanel = false
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 12) {
            Button(L("open_storage")) {
                showingOpenPanel = true
            }
            .buttonStyle(.borderedProminent)

            if appState.currentStorage != nil {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField(L("search_placeholder"), text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .onSubmit {
                            if !searchText.isEmpty {
                                appState.searchQuery = searchText
                                appState.isSearchMode = true
                            }
                        }
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
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
                    if let path = appState.currentStorage?.currentPath {
                        appState.currentStorage?.navigate(to: path)
                    }
                }

                Button(L("search")) {
                    showingSearchPanel = true
                }
                .fixedSize()
                .popover(isPresented: $showingSearchPanel) {
                    SearchPanelView(initialQuery: searchText)
                        .frame(minWidth: 700, minHeight: 420)
                }
            }

            Spacer()

            Button(action: {
                showingSettings = true
            }) {
                Image(systemName: "gear")
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .frame(minWidth: 480, minHeight: 520)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .fileImporter(
            isPresented: $showingOpenPanel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        let didStartAccessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if didStartAccessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        let storage = CascBridge.CascStorageHandle.createLocal()
                        let service = CASCStorageService(storage: storage)
                        await MainActor.run {
                            appState.currentStorage?.close()
                            appState.currentStorage = service
                        }
                        await service.openLocal(path: url.path)
                        if service.error != nil {
                            await MainActor.run {
                                appState.errorMessage = service.error?.localizedDescription
                            }
                        }
                    }
                }
            case .failure(let error):
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var showingClearCacheAlert = false
    @State private var cacheClearedSize = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("settings_storage")).font(.headline)) {
                    Toggle(L("cdn_download"), isOn: $settings.cdnDownloadEnabled)
                        .help(L("cdn_download_help"))

                    HStack {
                        Text(L("cdn_host_url"))
                        Spacer()
                        TextField(L("cdn_host_help"), text: $settings.cdnHostUrl)
                            .frame(width: 250)
                            .textFieldStyle(.roundedBorder)
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
            .frame(width: 480, height: 560)
            .navigationTitle(L("settings_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("reset_defaults")) {
                        settings.resetToDefaults()
                    }
                }
            }
            .alert(L("cache_cleared_title"), isPresented: $showingClearCacheAlert) {
                Button(L("ok"), role: .cancel) {}
            } message: {
                Text(cacheClearedSize)
            }
        }
    }

    private func chooseDefaultExtractPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("choose")

        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultExtractPath = url.path
        }
    }

    private func clearCache() {
        settings.clearCache()
        cacheClearedSize = L("cache_cleared_message")
        showingClearCacheAlert = true
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
