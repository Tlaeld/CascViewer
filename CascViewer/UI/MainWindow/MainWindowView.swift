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
