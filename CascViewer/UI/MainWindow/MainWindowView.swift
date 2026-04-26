import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var sidebarWidth: CGFloat = 250
    @State private var inspectorVisible = true

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()

            Divider()

            HSplitView {
                FileTreeView()
                    .frame(minWidth: 150, idealWidth: sidebarWidth, maxWidth: 400)

                VSplitView {
                    FileListView()

                    if inspectorVisible {
                        FilePreviewPanel()
                            .frame(minHeight: 100, idealHeight: 200)
                    }
                }
            }

            Divider()

            StatusBarView()
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}
