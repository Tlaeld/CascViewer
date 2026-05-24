import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            if let storage = appState.currentStorage {
                let currentCount = storage.currentChildren.count
                let totalCount = storage.allEntriesCount
                Text(L("status_current_folder", currentCount))
                    .font(.caption)
                Text("|")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(L("status_files", totalCount))
                    .font(.caption)
                if !appState.selectedPath.isEmpty {
                    Text("|")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L("status_selected", appState.selectedPath))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300)
                }
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
