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
    }
}
