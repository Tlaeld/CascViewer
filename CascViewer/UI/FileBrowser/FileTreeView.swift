import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState
    @State private var expandedItems = Set<String>()

    var body: some View {
        List {
            if let storage = appState.currentStorage {
                ForEach(storage.entries.filter { $0.isDirectory }) { entry in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedItems.contains(entry.fullPath) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedItems.insert(entry.fullPath)
                                    Task {
                                        await storage.listDirectory(path: entry.fullPath)
                                    }
                                } else {
                                    expandedItems.remove(entry.fullPath)
                                }
                            }
                        )
                    ) {
                        // Nested entries would be shown here in a full implementation
                        // For now, show a placeholder indicating children load on expand
                        Text("(children load on expand)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                }
            } else {
                Text("Open a storage to browse")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}
