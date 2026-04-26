import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            if let storage = appState.currentStorage {
                Text("Files: \(storage.entries.count)")
                    .font(.caption)
                Text("|")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let info = storage.storageInfo {
                    Text("Storage: \(info.productName) \(info.buildVersion)")
                        .font(.caption)
                }
            } else {
                Text("Ready")
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
