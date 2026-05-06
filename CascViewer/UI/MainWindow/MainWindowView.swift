import SwiftUI

struct LoadingOverlay: View {
    @ObservedObject var storage: CASCStorageService

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
                            .lineLimit(1)
                    }
                    
                    if storage.loadProgress > 0 {
                        Text("\(Int(storage.loadProgress * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(24)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 8)
                .frame(width: 280)
            }
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ToolbarView()
                Divider()

                HStack(spacing: 0) {
                    FileTreeView()
                        .frame(width: 220)

                    Divider()

                    VStack(spacing: 0) {
                        FileListView()
                            .frame(minHeight: 350)
                        Divider()
                        FilePreviewPanel()
                            .frame(minHeight: 160)
                    }
                }

                Divider()
                StatusBarView()
            }

            if let storage = appState.currentStorage {
                LoadingOverlay(storage: storage)
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
    }
}
