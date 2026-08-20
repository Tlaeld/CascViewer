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
                    .font(DS.Fonts.caption)
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xs)
            .background(DS.Colors.panelBackground)
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
                .font(DS.Fonts.caption)
            Text("|")
                .font(DS.Fonts.caption)
                .foregroundColor(.secondary)
            Text(L("status_files", totalCount))
                .font(DS.Fonts.caption)
            if !appState.selectedPath.isEmpty {
                Text("|")
                    .font(DS.Fonts.caption)
                    .foregroundColor(.secondary)
                Text(L("status_selected", appState.selectedPath))
                    .font(DS.Fonts.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300)
            }
            if let info = storage.storageInfo {
                Text("|")
                    .font(DS.Fonts.caption)
                    .foregroundColor(.secondary)
                Text(L("status_storage", info.productName, info.buildVersion))
                    .font(DS.Fonts.caption)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Colors.panelBackground)
    }
}
