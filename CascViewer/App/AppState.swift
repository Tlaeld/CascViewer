import Foundation
import Combine
import SwiftUI

import CascBridge

@MainActor
final class AppState: ObservableObject {
    @Published var currentStorage: CASCStorageService?
    @Published var selectedPath: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Search mode (integrated into main UI, persistent state)
    @Published var isSearchMode: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchMode: SearchMode = .filename
    @Published var searchScope: SearchScope = .entireStorage
    @Published var searchUseRegex: Bool = false
    @Published var searchCaseSensitive: Bool = false
    @Published var searchIncludePath: Bool = false
    @Published var searchSelectedTypes: Set<String> = []
    @Published var searchCustomExtension: String = ""
    @Published var searchSelectedTags: Set<String> = []
    @Published var searchResults: [SearchMatch] = []
    @Published var searchIsSearching: Bool = false
    @Published var searchSortBy: SearchSortBy = .name
    @Published var searchSortAscending: Bool = true
}

extension AppState {
    func showInstallManifestWindow() {
        guard let storage = currentStorage else { return }
        guard let window = NSApp.keyWindow else { return }

        let alert = NSAlert()
        alert.messageText = L("loading_install_manifest")
        alert.informativeText = L("please_wait")
        alert.alertStyle = .informational
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 200, height: 16))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        alert.addButton(withTitle: L("cancel"))

        var wasCancelled = false
        alert.beginSheetModal(for: window) { _ in
            wasCancelled = true
        }

        Task {
            let manifest = await storage.loadInstallManifest()
            await MainActor.run {
                guard !wasCancelled else { return }
                alert.window.sheetParent?.endSheet(alert.window)
                if let manifest = manifest {
                    InstallManifestWindowController.show(
                        tags: manifest.tags,
                        entries: manifest.entries,
                        storageService: storage
                    )
                } else {
                    self.errorMessage = L("install_manifest_not_found")
                }
            }
        }
    }
}
