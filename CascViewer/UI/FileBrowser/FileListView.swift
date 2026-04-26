import SwiftUI
import AppKit
import CascBridge

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = Set<CASCFileEntry.ID>()
    @State private var showingExtractDialog = false
    @State private var entryMap: [CASCFileEntry.ID: CASCFileEntry] = [:]

    var body: some View {
        Group {
            if let storage = appState.currentStorage {
                fileTable(for: storage)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showingExtractDialog) {
            ExtractDialogView(entries: selectedEntries) { destination, preserveStructure, overwriteExisting, openAfterExtract in
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
               let entry = entryMap[id] {
                appState.selectedPath = entry.fullPath
            } else {
                appState.selectedPath = ""
            }
        }
        .onChange(of: storage.entries) { newEntries in
            selection.removeAll()
            entryMap = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.id, $0) })
        }
        .contextMenu(forSelectionType: CASCFileEntry.ID.self) { items in
            if !items.isEmpty {
                Button("Extract to...") {
                    showingExtractDialog = true
                }
            }
            Button("Copy Path") {
                // Copy to clipboard
            }
        } primaryAction: { items in
            if let id = items.first,
               let entry = entryMap[id],
               !entry.isDirectory,
               entry.name.lowercased().hasSuffix(".blp") {
                Task {
                    var error = CascBridge.CascError.None
                    let data = storage.handle.readFile(std.string(entry.fullPath), &error)
                    guard error == .None, !data.isEmpty else { return }
                    let blpData = Data(data.map { $0 })
                    await MainActor.run {
                        let window = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered,
                            defer: false
                        )
                        window.title = entry.name
                        window.contentView = NSHostingView(rootView: BLPViewerWindow(fileName: entry.name, imageData: blpData))
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
    }

    private var selectedEntries: [CASCFileEntry] {
        selection.compactMap { entryMap[$0] }
    }

    private func performExtract(to destination: URL, preserveStructure: Bool) {
        guard let handle = appState.currentStorage?.handle else {
            appState.errorMessage = "No storage is currently open."
            return
        }
        guard !selectedEntries.isEmpty else {
            appState.errorMessage = "No files selected for extraction."
            return
        }
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
