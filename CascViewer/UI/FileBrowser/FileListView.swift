import SwiftUI

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = Set<CASCFileEntry.ID>()

    var body: some View {
        Group {
            if let storage = appState.currentStorage {
                Table(of: CASCFileEntry.self, selection: $selection) {
                    TableColumn("Name") { entry in
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                            Text(entry.name)
                        }
                    }
                    TableColumn("Size") { entry in
                        Text(entry.formattedSize)
                    }
                    TableColumn("Type") { entry in
                        Text(entry.isDirectory ? "Folder" : (URL(fileURLWithPath: entry.name).pathExtension.uppercased()))
                    }
                } rows: {
                    ForEach(storage.entries) { entry in
                        TableRow(entry)
                    }
                }
                .onChange(of: selection) { newSelection in
                    if let id = newSelection.first,
                       let entry = storage.entries.first(where: { $0.id == id }) {
                        appState.selectedPath = entry.fullPath
                    }
                }
                .contextMenu(forSelectionType: CASCFileEntry.ID.self) { items in
                    Button("Extract...") {
                        // Extract selected
                    }
                    Button("Copy Path") {
                        // Copy to clipboard
                    }
                } primaryAction: { items in
                    if let id = items.first,
                       let entry = storage.entries.first(where: { $0.id == id }),
                       !entry.isDirectory,
                       entry.name.lowercased().hasSuffix(".blp") {
                        // Open BLP viewer — will be implemented in Task 14
                    }
                }
            } else {
                VStack {
                    Image(systemName: "archivebox")
                    Text("No Storage Open")
                }
                .foregroundColor(.secondary)
            }
        }
    }
}
