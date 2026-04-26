import SwiftUI

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = Set<CASCFileEntry.ID>()
    @State private var showingExtractDialog = false

    var body: some View {
        Group {
            if let storage = appState.currentStorage {
                fileTable(for: storage)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showingExtractDialog) {
            ExtractDialogView(entries: selectedEntries) { destination, preserveStructure in
                performExtract(to: destination, preserveStructure: preserveStructure)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack {
            Image(systemName: "archivebox")
            Text("No Storage Open")
        }
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func fileTable(for storage: CASCStorageService) -> some View {
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
                Text(entry.isDirectory ? "Folder" : fileExtension(for: entry.name))
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
        .onChange(of: storage.entries) { _ in
            selection.removeAll()
        }
        .contextMenu(forSelectionType: CASCFileEntry.ID.self) { items in
            Button("Extract to...") {
                showingExtractDialog = true
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
    }

    private var selectedEntries: [CASCFileEntry] {
        guard let storage = appState.currentStorage else { return [] }
        return storage.entries.filter { selection.contains($0.id) }
    }

    private func performExtract(to destination: URL, preserveStructure: Bool) {
        guard let handle = appState.currentStorageHandle, !selectedEntries.isEmpty else { return }
        Task {
            let extractService = CASCExtractService(storage: handle)
            do {
                try await extractService.extract(
                    entries: selectedEntries,
                    to: destination,
                    preserveStructure: preserveStructure
                )
            } catch {
                appState.errorMessage = "Extraction failed: \(error.localizedDescription)"
            }
        }
    }

    private func fileExtension(for name: String) -> String {
        (name as NSString).pathExtension.uppercased()
    }
}
