import SwiftUI

@main
struct CascViewerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                Divider()
                Button(L("open_install_manifest")) {
                    appState.showInstallManifestWindow()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(appState.currentStorage == nil)
            }
        }
    }
}
