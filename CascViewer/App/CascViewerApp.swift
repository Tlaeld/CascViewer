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
                    guard let storage = appState.currentStorage else { return }
                    let alert = NSAlert()
                    alert.messageText = L("loading_install_manifest")
                    alert.informativeText = L("please_wait")
                    alert.alertStyle = .informational
                    let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 200, height: 16))
                    indicator.style = .bar
                    indicator.isIndeterminate = true
                    indicator.startAnimation(nil)
                    alert.accessoryView = indicator
                    alert.addButton(withTitle: L("cancel"))
                    guard let window = NSApp.keyWindow else { return }
                    alert.beginSheetModal(for: window) { _ in }
                    Task {
                        let manifest = await storage.loadInstallManifest()
                        await MainActor.run {
                            alert.window.sheetParent?.endSheet(alert.window)
                            if let manifest = manifest {
                                InstallManifestWindowController.show(
                                    tags: manifest.tags,
                                    entries: manifest.entries,
                                    storageService: storage
                                )
                            } else {
                                appState.errorMessage = L("install_manifest_not_found")
                            }
                        }
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(appState.currentStorage == nil)
            }
        }
    }
}
