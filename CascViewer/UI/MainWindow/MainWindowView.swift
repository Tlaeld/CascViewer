import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var sidebarWidth: CGFloat = 250
    @State private var inspectorVisible = true

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
                .environmentObject(appState)

            Divider()

            HSplitView {
                FileTreeView()
                    .environmentObject(appState)
                    .frame(minWidth: 150, idealWidth: sidebarWidth, maxWidth: 400)

                VSplitView {
                    FileListView()
                        .environmentObject(appState)

                    if inspectorVisible {
                        FilePreviewPanel()
                            .environmentObject(appState)
                            .frame(minHeight: 100, idealHeight: 200)
                    }
                }
            }

            Divider()

            StatusBarView()
                .environmentObject(appState)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
