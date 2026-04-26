import SwiftUI
import CascBridge

struct ToolbarView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var showingOpenPanel = false
    @State private var showingSearchPanel = false

    var body: some View {
        HStack(spacing: 12) {
            Button("Open Storage") {
                showingOpenPanel = true
            }
            .buttonStyle(.borderedProminent)

            if appState.currentStorage != nil {
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit {
                        // Trigger search
                    }

                Button("Refresh") {
                    Task {
                        await appState.currentStorage?.listDirectory(path: appState.currentStorage?.currentPath ?? "")
                    }
                }

                Button("Search") {
                    showingSearchPanel = true
                }
                .sheet(isPresented: $showingSearchPanel) {
                    SearchPanelView()
                        .frame(minWidth: 500, minHeight: 600)
                }
            }

            Spacer()

            Button(action: {
                // Settings
            }) {
                Image(systemName: "gear")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .fileImporter(
            isPresented: $showingOpenPanel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        let didStartAccessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if didStartAccessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        let storage = CascBridge.CascStorageHandle.createLocal()
                        let service = CASCStorageService(storage: storage)
                        await service.openLocal(path: url.path)
                        if service.error == nil {
                            await MainActor.run {
                                appState.currentStorage?.close()
                                appState.currentStorage = service
                            }
                        } else {
                            await MainActor.run {
                                appState.errorMessage = service.error?.localizedDescription
                            }
                        }
                    }
                }
            case .failure(let error):
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}
