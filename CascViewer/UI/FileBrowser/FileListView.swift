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
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.6))
            Text("No Storage Open")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private func fileTable(for storage: CASCStorageService) -> some View {
        let sorted = sortedEntries(storage.entries)
        Table(of: CASCFileEntry.self, selection: $selection) {
            nameColumn
            pathColumn
            sizeColumn
            typeColumn
        } rows: {
            ForEach(sorted) { entry in
                TableRow(entry)
            }
        }
        .tableStyle(.bordered)
        .onAppear {
            entryMap = Dictionary(uniqueKeysWithValues: storage.entries.map { ($0.id, $0) })
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
            contextMenuItems(for: items)
        } primaryAction: { items in
            handlePrimaryAction(items: items, storage: storage)
        }
    }

    // MARK: - Table Columns

    private var nameColumn: some TableColumnContent<CASCFileEntry, Never> {
        TableColumn("Name") { entry in
            HStack(spacing: 6) {
                Image(systemName: iconFor(entry: entry))
                    .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(entry.name)
                    .font(.system(size: 12))
            }
            .padding(.vertical, 2)
        }
    }

    private var pathColumn: some TableColumnContent<CASCFileEntry, Never> {
        TableColumn("Path") { entry in
            Text(entry.fullPath)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var sizeColumn: some TableColumnContent<CASCFileEntry, Never> {
        TableColumn("Size") { entry in
            Text(entry.formattedSize)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var typeColumn: some TableColumnContent<CASCFileEntry, Never> {
        TableColumn("Type") { entry in
            Text(entry.isDirectory ? "Folder" : fileExtension(for: entry.name))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Context Menu & Actions

    @ViewBuilder
    private func contextMenuItems(for items: Set<CASCFileEntry.ID>) -> some View {
        if !items.isEmpty {
            Button("Extract to...") {
                showingExtractDialog = true
            }
        }
        Button("Copy Path") {
            if let id = items.first, let entry = entryMap[id] {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.fullPath, forType: .string)
            }
        }
    }

    private func handlePrimaryAction(items: Set<CASCFileEntry.ID>, storage: CASCStorageService) {
        guard let id = items.first,
              let entry = entryMap[id],
              !entry.isDirectory,
              entry.name.lowercased().hasSuffix(".blp") else { return }

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

    // MARK: - Helpers

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

    private func sortedEntries(_ entries: [CASCFileEntry]) -> [CASCFileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func fileExtension(for name: String) -> String {
        (name as NSString).pathExtension.uppercased()
    }

    private func iconFor(entry: CASCFileEntry) -> String {
        if entry.isDirectory {
            return "folder.fill"
        }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "blp", "png", "jpg", "jpeg", "tga", "gif":
            return "photo"
        case "xml", "html", "htm", "txt", "md":
            return "doc.text"
        case "lua", "js", "ts", "swift", "cpp", "c", "h":
            return "curlybraces"
        case "mp3", "wav", "ogg", "flac":
            return "music.note"
        case "mp4", "avi", "mov", "mkv":
            return "film"
        case "pdf":
            return "doc.text.fill"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        case "db", "dbc", "dbf":
            return "tablecells"
        default:
            return "doc"
        }
    }
}
