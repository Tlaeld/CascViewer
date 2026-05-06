import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            if let storage = appState.currentStorage {
                Text(L("status_files", storage.allEntriesCount))
                    .font(.caption)
                Text("|")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let info = storage.storageInfo {
                    Text(L("status_storage", info.productName, info.buildVersion))
                        .font(.caption)
                }
            } else {
                Text(L("status_ready"))
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
