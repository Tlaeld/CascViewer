import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let storage = appState.currentStorage {
            StatusBarContentView(storage: storage)
                .environmentObject(appState)
        } else {
            HStack(spacing: 8) {
                Text(L("status_ready"))
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

private struct StatusBarContentView: View {
    @ObservedObject var storage: CASCStorageService
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
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
            if let info = storage.storageInfo {
                Text("|")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(L("status_storage", info.productName, info.buildVersion))
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
