import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Text("CascViewer - Main Window")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
