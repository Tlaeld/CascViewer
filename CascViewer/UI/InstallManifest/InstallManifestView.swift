import SwiftUI
import AppKit
import CascBridge
import UniformTypeIdentifiers

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
    @State private var filteredEntries: [InstallManifestEntry] = []
    @State private var filterTask: Task<Void, Never>? = nil
    @State private var csvDocument = CSVDocument(text: "")

    enum SortColumn {
        case fileName, fileSize, ckey
    }

    private func updateFilteredEntries(debounce: Bool = false) {
        filterTask?.cancel()
        let localSearchText = searchText
        let localSelectedTags = selectedTagIndices
        let localSortColumn = sortColumn
        let localSortAscending = sortAscending
        let localEntries = entries

        filterTask = Task { @MainActor in
            if debounce, !localSearchText.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .userInitiated) {
                var result = localEntries

                if !localSelectedTags.isEmpty {
                    result = result.filter { entry in
                        localSelectedTags.allSatisfy { index in
                            entry.hasTag(at: index)
                        }
                    }
                }

                if !localSearchText.isEmpty {
                    let lowerQuery = localSearchText.lowercased()
                    result = result.filter {
                        $0.fileName.lowercased().contains(lowerQuery) ||
                        $0.ckey.lowercased().contains(lowerQuery)
                    }
                }

                result.sort {
                    let cmp: Bool
                    switch localSortColumn {
                    case .fileName:
                        cmp = $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                    case .fileSize:
                        cmp = $0.fileSize < $1.fileSize
                    case .ckey:
                        cmp = $0.ckey < $1.ckey
                    }
                    return localSortAscending ? cmp : !cmp
                }

                return result
            }.value

            guard !Task.isCancelled else { return }
            filteredEntries = result
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                TextField(L("search_placeholder"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onChange(of: searchText) { _ in updateFilteredEntries(debounce: true) }

                if !tags.isEmpty {
                    Menu(L("filter_tags")) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                            Button {
                                if selectedTagIndices.contains(index) {
                                    selectedTagIndices.remove(index)
                                } else {
                                    selectedTagIndices.insert(index)
                                }
                                updateFilteredEntries(debounce: false)
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
                        let selected = filteredEntries.filter { selectedEntryIDs.contains($0.id) }
                        exportConfig = ExportSheetConfig(entries: selected)
                    } label: {
                        Label(L("export_selected", selectedEntryIDs.count), systemImage: "arrow.down.doc")
                    }
                }

                if selectedEntryIDs.count == 1,
                   let id = selectedEntryIDs.first,
                   let entry = filteredEntries.first(where: { $0.id == id }) {
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
                    updateFilteredEntries(debounce: false)
                }
            )
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            updateFilteredEntries(debounce: false)
        }
        .onDisappear {
            filterTask?.cancel()
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
            document: csvDocument,
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

    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    private func buildCSVContent() -> String {
        var lines: [String] = []
        lines.reserveCapacity(filteredEntries.count + 1)
        lines.append("FileName,Size,CKey,Tags")
        for entry in filteredEntries {
            let tagNames = tags.enumerated().compactMap { index, tag -> String? in
                entry.hasTag(at: index) ? tag.name : nil
            }.joined(separator: ";")
            lines.append("\(csvEscape(entry.fileName)),\(entry.fileSize),\(entry.ckey),\(csvEscape(tagNames))")
        }
        return lines.joined(separator: "\n")
    }

    private func exportList() {
        csvDocument = CSVDocument(text: buildCSVContent())
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
