import SwiftUI
import AppKit
import CascBridge
import UniformTypeIdentifiers

struct TagCell: View {
    let entry: InstallManifestEntry
    let tags: [InstallManifestTag]

    var ownedTags: [(offset: Int, element: InstallManifestTag)] {
        tags.enumerated().filter { entry.hasTag(at: $0.offset) }
    }

    var body: some View {
        HStack(spacing: 4) {
            let maxVisible = 3
            let visible = Array(ownedTags.prefix(maxVisible))
            ForEach(visible, id: \.offset) { item in
                Text(item.element.name)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(3)
            }
            if ownedTags.count > maxVisible {
                Text("+\(ownedTags.count - maxVisible)")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
            }
        }
        .help(ownedTags.map { $0.element.name }.joined(separator: ", "))
    }
}

struct InstallManifestView: View {
    let tags: [InstallManifestTag]
    let entries: [InstallManifestEntry]
    let storageService: CASCStorageService?

    @State private var selectedTagIndices: Set<Int> = []
    @State private var searchText: String = ""
    @State private var sortColumn: SortColumn = .fileName
    @State private var sortAscending: Bool = true
    @State private var selectedEntryIDs: Set<String> = []
    @State private var showingDetail = false
    @State private var detailEntry: InstallManifestEntry?
    @State private var exportConfig: ExportSheetConfig? = nil
    @State private var showingListExportPanel = false
    @State private var exportResultMessage: String?
    @State private var showingExportResult = false

    enum SortColumn {
        case fileName, fileSize, ckey
    }

    var filteredEntries: [InstallManifestEntry] {
        var result = entries

        // Filter by selected tags
        if !selectedTagIndices.isEmpty {
            result = result.filter { entry in
                selectedTagIndices.allSatisfy { index in
                    entry.hasTag(at: index)
                }
            }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let lowerQuery = searchText.lowercased()
            result = result.filter {
                $0.fileName.lowercased().contains(lowerQuery) ||
                $0.ckey.lowercased().contains(lowerQuery)
            }
        }

        // Sort
        result.sort {
            let cmp: Bool
            switch sortColumn {
            case .fileName:
                cmp = $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            case .fileSize:
                cmp = $0.fileSize < $1.fileSize
            case .ckey:
                cmp = $0.ckey < $1.ckey
            }
            return sortAscending ? cmp : !cmp
        }

        return result
    }

    var selectedEntries: [InstallManifestEntry] {
        filteredEntries.filter { selectedEntryIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                TextField(L("search_placeholder"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                if !tags.isEmpty {
                    Menu(L("filter_tags")) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                            Button {
                                if selectedTagIndices.contains(index) {
                                    selectedTagIndices.remove(index)
                                } else {
                                    selectedTagIndices.insert(index)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selectedTagIndices.contains(index) ? "checkmark.square" : "square")
                                    Text(tag.name)
                                }
                            }
                        }
                    }
                }

                Button {
                    exportList()
                } label: {
                    Label(L("export_list"), systemImage: "square.and.arrow.up")
                }
                .disabled(filteredEntries.isEmpty)

                if !selectedEntryIDs.isEmpty {
                    Button {
                        exportConfig = ExportSheetConfig(entries: selectedEntries)
                    } label: {
                        Label(L("export_selected", selectedEntryIDs.count), systemImage: "arrow.down.doc")
                    }
                }

                if selectedEntryIDs.count == 1, let entry = selectedEntries.first {
                    Button {
                        detailEntry = entry
                        showingDetail = true
                    } label: {
                        Label(L("view_details"), systemImage: "info.circle")
                    }
                }

                Spacer()

                Text("\(filteredEntries.count) / \(entries.count) \(L("files"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // NSTableView bridge for performance
            InstallManifestTableView(
                entries: filteredEntries,
                tags: tags,
                selectedIDs: selectedEntryIDs,
                sortColumn: sortColumn,
                sortAscending: sortAscending,
                onSelect: { ids in
                    selectedEntryIDs = ids
                },
                onDoubleClick: { entry in
                    detailEntry = entry
                    showingDetail = true
                },
                onExport: { entry in
                    exportConfig = ExportSheetConfig(entries: [entry])
                },
                onSort: { column, ascending in
                    sortColumn = column
                    sortAscending = ascending
                }
            )
            .frame(maxHeight: .infinity)
        }
        .sheet(item: $detailEntry) { entry in
            InstallManifestEntryDetailView(
                entry: entry,
                tags: tags,
                storageService: storageService
            )
        }
        .sheet(item: $exportConfig) { config in
            InstallManifestExportSheet(
                entries: config.entries,
                storageService: storageService,
                onComplete: { message in
                    if let message = message {
                        exportResultMessage = message
                        showingExportResult = true
                    }
                }
            )
        }
        .fileExporter(
            isPresented: $showingListExportPanel,
            document: CSVDocument(text: csvContent),
            contentType: .commaSeparatedText,
            defaultFilename: "install_manifest.csv"
        ) { result in
            if case .failure(let error) = result {
                exportResultMessage = error.localizedDescription
                showingExportResult = true
            }
        }
        .alert(L("export_result_title"), isPresented: $showingExportResult, presenting: exportResultMessage) { _ in
            Button(L("ok"), role: .cancel) { }
        } message: { message in
            Text(message)
        }
    }

    private var csvContent: String {
        var lines: [String] = []
        lines.append("FileName,Size,CKey,Tags")
        for entry in filteredEntries {
            let tagNames = tags.enumerated().compactMap { index, tag -> String? in
                entry.hasTag(at: index) ? tag.name : nil
            }.joined(separator: ";")
            let escapedName = entry.fileName.contains(",") ? "\"\(entry.fileName)\"" : entry.fileName
            lines.append("\(escapedName),\(entry.fileSize),\(entry.ckey),\(tagNames)")
        }
        return lines.joined(separator: "\n")
    }

    private func exportList() {
        showingListExportPanel = true
    }
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}
