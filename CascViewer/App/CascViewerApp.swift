import SwiftUI

@main
struct CascViewerApp: App {
    var body: some Scene {
        WindowGroup {
            MainWindowView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
    }
}
