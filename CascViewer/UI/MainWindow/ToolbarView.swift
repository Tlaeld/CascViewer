import SwiftUI
import CascBridge

struct ToolbarView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var showingOpenPanel = false

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
                    let didStartAccessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    Task {
                        let storage = CascBridge.CascStorageHandle.createLocal()
                        let service = CASCStorageService(storage: storage)
                        await service.openLocal(path: url.path)
                        if service.error == nil {
                            appState.currentStorage?.close()
                            appState.currentStorage = service
                        } else {
                            appState.errorMessage = service.error?.localizedDescription
                        }
                    }
                }
            case .failure(let error):
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}
