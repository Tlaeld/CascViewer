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

@MainActor
final class InstallManifestExtractService: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    @Published var isExporting: Bool = false
    
    private class ProgressContext {
        weak var service: InstallManifestExtractService?
        let fileIndex: Int
        let totalFiles: Int
        
        init(service: InstallManifestExtractService, fileIndex: Int, totalFiles: Int) {
            self.service = service
            self.fileIndex = fileIndex
            self.totalFiles = totalFiles
        }
    }
    
    func extract(entries: [InstallManifestEntry], destination: URL, preserveStructure: Bool, storageService: CASCStorageService) async -> (success: Int, skipped: Int, failed: [String]) {
        isExporting = true
        progress = 0
        defer { isExporting = false }
        
        let total = entries.count
        var failed: [String] = []
        var skipped = 0
        
        for (index, entry) in entries.enumerated() {
            await MainActor.run {
                progress = Double(index) / Double(total)
                currentFile = entry.fileName
            }
            
            // Use CKey as cascPath so CascLib can find files not in ROOT handler
            let cascPath = entry.ckey
            let destPath: String
            if preserveStructure {
                destPath = destination.appendingPathComponent(entry.fileName).path
            } else {
                let safeName = entry.fileName.components(separatedBy: "/").last ?? entry.fileName
                destPath = destination.appendingPathComponent(safeName).path
            }
            
            let parentDir = URL(fileURLWithPath: destPath).deletingLastPathComponent().path
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: parentDir), withIntermediateDirectories: true)
            
            var handle = storageService.handle
            
            let error: CascBridge.CascError = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let progressCtx = ProgressContext(service: self, fileIndex: index, totalFiles: total)
                    let rawContext = Unmanaged.passUnretained(progressCtx).toOpaque()
                    
                    let progressBlock: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64) -> Void = { context, current, totalBytes in
                        guard let ctxPtr = context else { return }
                        guard totalBytes > 0 else { return }
                        let ctx = Unmanaged<ProgressContext>.fromOpaque(ctxPtr).takeUnretainedValue()
                        guard let service = ctx.service else { return }
                        let fileProgress = Double(current) / Double(totalBytes)
                        let overallProgress = (Double(ctx.fileIndex) + fileProgress) / Double(ctx.totalFiles)
                        if ctx.fileIndex == 0 || current == totalBytes {
                            NSLog("[InstallManifestExtract] progress callback: file \(ctx.fileIndex)/\(ctx.totalFiles), current=\(current), total=\(totalBytes), overall=\(overallProgress)")
                        }
                        DispatchQueue.main.async {
                            service.progress = overallProgress
                        }
                    }
                    
                    let result = handle.extractFile(
                        std.string(cascPath),
                        std.string(destPath),
                        progressBlock,
                        rawContext
                    )
                    continuation.resume(returning: result)
                }
            }
            
            if error == .FileNotFound {
                NSLog("[InstallManifestExtract] file \(index): \(entry.fileName) -> FileNotFound (skipped)")
                skipped += 1
                continue
            } else if error != .None {
                let reason = error.localizedDescription
                NSLog("[InstallManifestExtract] file \(index): \(entry.fileName) -> error: \(reason) (raw: \(error))")
                failed.append("\(entry.fileName): \(reason)")
            } else {
                NSLog("[InstallManifestExtract] file \(index): \(entry.fileName) -> success")
            }
        }
        
        return (success: entries.count - failed.count - skipped, skipped: skipped, failed: failed)
    }
}

private struct ExportSheetConfig: Identifiable {
    let id = UUID()
    let entries: [InstallManifestEntry]
}

struct InstallManifestExportSheet: View {
    let entries: [InstallManifestEntry]
    let storageService: CASCStorageService?
    let onComplete: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var destination: URL
    @State private var preserveStructure = true
    @State private var showingPicker = false
    @StateObject private var extractService = InstallManifestExtractService()
    @State private var showingDownloadConfirm = false
    @State private var remoteEntries: [InstallManifestEntry] = []
    @State private var exportResult: (success: Int, skipped: Int, failed: [String])? = nil
    
    init(entries: [InstallManifestEntry], storageService: CASCStorageService?, onComplete: @escaping (String?) -> Void) {
        self.entries = entries
        self.storageService = storageService
        self.onComplete = onComplete
        let defaultURL = AppSettings.shared.defaultExtractURL
        _destination = State(initialValue: defaultURL)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("export_title", entries.count))
                .font(.headline)
            
            if let result = exportResult {
                // Result view
                resultView(result)
            } else {
                // Export config view
                HStack {
                    Text(L("destination") + ":")
                    Text(destination.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L("browse")) {
                        showingPicker = true
                    }
                }
                
                Toggle(L("keep_structure"), isOn: $preserveStructure)
                
                if extractService.isExporting {
                    VStack(spacing: 8) {
                        ProgressView(value: extractService.progress, total: 1.0)
                        Text(extractService.currentFile)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Spacer()
                    Button(L("cancel")) { dismiss() }
                        .disabled(extractService.isExporting)
                    Button(L("export")) {
                        performExport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(extractService.isExporting || storageService == nil)
                }
            }
        }
        .padding()
        .frame(width: 450)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                destination = url
            }
        }
        .alert(L("download_required_title"), isPresented: $showingDownloadConfirm, presenting: remoteEntries) { entries in
            Button(L("download_and_export"), role: .none) {
                performExport()
            }
            Button(L("cancel"), role: .cancel) { }
        } message: { entries in
            let totalSize = entries.reduce(0) { $0 + Int64($1.fileSize) }
            let sizeStr = ByteCountFormatter().string(fromByteCount: totalSize)
            Text(L("download_required_export_message", entries.count, sizeStr))
        }
    }
    
    @ViewBuilder
    private func resultView(_ result: (success: Int, skipped: Int, failed: [String])) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.success > 0 {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(L("extract_success", result.success))
                }
            }
            
            if result.skipped > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L("extract_skipped", result.skipped))
                }
            }
            
            if !result.failed.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("extract_partial", result.success, result.failed.count))
                            .foregroundColor(.red)
                        ForEach(result.failed.prefix(5), id: \.self) { msg in
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if result.failed.count > 5 {
                            Text("... \(result.failed.count - 5) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            HStack {
                Spacer()
                Button(L("done")) {
                    var parts: [String] = []
                    if result.success > 0 {
                        parts.append(L("extract_success", result.success))
                    }
                    if result.skipped > 0 {
                        parts.append(L("extract_skipped", result.skipped))
                    }
                    if !result.failed.isEmpty {
                        let failedMsg = result.failed.prefix(5).joined(separator: "\n") + (result.failed.count > 5 ? "\n... \(result.failed.count - 5) more" : "")
                        parts.append(L("extract_partial", result.success, result.failed.count) + "\n" + failedMsg)
                    }
                    onComplete(parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
    
    private func performExport() {
        guard let service = storageService else { return }
        
        // Check if any files are not local
        let remote = entries.filter { entry in
            guard let fileEntry = service.entry(forPath: entry.fileName) else { return true }
            return !fileEntry.isLocal
        }
        
        NSLog("[InstallManifestExport] total entries: \(entries.count), remote: \(remote.count), isOnline: \(service.isOnlineStorage)")
        
        // Local storage cannot download missing files from CDN
        if !service.isOnlineStorage && !remote.isEmpty {
            Task {
                let localEntries = entries.filter { entry in
                    guard let fileEntry = service.entry(forPath: entry.fileName) else { return false }
                    return fileEntry.isLocal
                }
                let localResult = await extractService.extract(
                    entries: localEntries,
                    destination: destination,
                    preserveStructure: preserveStructure,
                    storageService: service
                )
                var failed = localResult.failed
                if !remote.isEmpty {
                    failed.append(L("local_storage_cannot_download", remote.count))
                }
                await MainActor.run {
                    exportResult = (
                        success: localResult.success,
                        skipped: localResult.skipped,
                        failed: failed
                    )
                }
            }
            return
        }
        
        // Online storage: show download confirmation if needed
        if !remote.isEmpty && !showingDownloadConfirm {
            remoteEntries = remote
            showingDownloadConfirm = true
            return
        }
        
        Task {
            let result = await extractService.extract(
                entries: entries,
                destination: destination,
                preserveStructure: preserveStructure,
                storageService: service
            )
            
            await MainActor.run {
                exportResult = result
            }
        }
    }
}
struct InstallManifestEntryDetailView: View {
    let entry: InstallManifestEntry
    let tags: [InstallManifestTag]
    let storageService: CASCStorageService?
    @Environment(\.dismiss) private var dismiss
    @State private var fileExists = false
    @State private var actualSize: UInt64?
    @State private var isLocal = false
    
    var ownedTags: [InstallManifestTag] {
        tags.enumerated().compactMap { index, tag in
            entry.hasTag(at: index) ? tag : nil
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("file_details"))
                    .font(.title2)
                Spacer()
                Button(L("close")) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DetailSection(title: L("basic_info")) {
                        DetailRow(label: L("file_name"), value: entry.fileName)
                        DetailRow(label: L("file_size"), value: entry.formattedSize)
                        DetailRow(label: L("ckey"), value: entry.ckey)
                        if let actualSize = actualSize {
                            DetailRow(label: L("actual_size"), value: ByteCountFormatter().string(fromByteCount: Int64(actualSize)))
                        }
                        if storageService != nil {
                            HStack {
                                Text(L("file_status"))
                                    .foregroundColor(.secondary)
                                    .frame(width: 100, alignment: .trailing)
                                HStack(spacing: 4) {
                                    Image(systemName: fileExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(fileExists ? .green : .red)
                                    Text(fileExists ? L("available") : L("not_available"))
                                }
                            }
                        }
                    }
                    
                    if !ownedTags.isEmpty {
                        DetailSection(title: L("tags")) {
                            FlowLayout(spacing: 8) {
                                ForEach(ownedTags) { tag in
                                    Text(tag.name)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            checkFileAvailability()
        }
    }
    
    private func checkFileAvailability() {
        guard let service = storageService else { return }
        Task {
            let path = entry.fileName.replacingOccurrences(of: "/", with: "\\")
            var error = CascBridge.CascError.None
            var handle = service.handle
            let data = handle.readFile(std.string(path), &error)
            let exists = error == .None && !data.isEmpty
            let size = exists ? UInt64(data.count) : nil
            await MainActor.run {
                self.fileExists = exists
                self.actualSize = size
            }
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(nil)
            Spacer()
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}


// MARK: - NSTableView Bridge

final class InstallManifestTableViewController: NSViewController {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    
    var entries: [InstallManifestEntry] = []
    var tags: [InstallManifestTag] = []
    var selectedIDs: Set<String> = []
    var sortColumn: InstallManifestView.SortColumn = .fileName
    var sortAscending: Bool = true
    var onSelect: ((Set<String>) -> Void)?
    var onDoubleClick: ((InstallManifestEntry) -> Void)?
    var onExport: ((InstallManifestEntry) -> Void)?
    var onSort: ((InstallManifestView.SortColumn, Bool) -> Void)?
    
    private var tagTextCache: [String: String] = [:]
    private var isProgrammaticSelection = false
    
    override func loadView() {
        view = NSView()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        tableView = NSTableView()
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = NSColor.controlBackgroundColor
        
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = L("file_name")
        nameCol.width = 350
        nameCol.minWidth = 150
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(nameCol)
        
        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = L("file_size")
        sizeCol.width = 90
        sizeCol.minWidth = 60
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(sizeCol)
        
        let ckeyCol = NSTableColumn(identifier: .init("ckey"))
        ckeyCol.title = L("ckey")
        ckeyCol.width = 260
        ckeyCol.minWidth = 180
        ckeyCol.sortDescriptorPrototype = NSSortDescriptor(key: "ckey", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(ckeyCol)
        
        let tagsCol = NSTableColumn(identifier: .init("tags"))
        tagsCol.title = L("tags")
        tagsCol.width = 160
        tagsCol.minWidth = 80
        tableView.addTableColumn(tagsCol)
        
        scrollView.documentView = tableView
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }
    
    func reload(entries: [InstallManifestEntry], tags: [InstallManifestTag], selectedIDs: Set<String>, sortColumn: InstallManifestView.SortColumn, sortAscending: Bool) {
        let entriesChanged = self.entries.count != entries.count || zip(self.entries, entries).contains(where: { $0.id != $1.id })
        let tagsChanged = self.tags.count != tags.count
        
        if entriesChanged || tagsChanged {
            self.entries = entries
            self.tags = tags
            rebuildTagCache()
            tableView.reloadData()
        }
        
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
        self.selectedIDs = selectedIDs
        updateSelection()
        updateSortIndicators()
    }
    
    private func rebuildTagCache() {
        tagTextCache.removeAll(keepingCapacity: true)
        tagTextCache.reserveCapacity(entries.count)
        for entry in entries {
            let owned = tags.enumerated().compactMap { index, tag -> String? in
                entry.hasTag(at: index) ? tag.name : nil
            }
            if owned.count <= 3 {
                tagTextCache[entry.id] = owned.joined(separator: ", ")
            } else {
                tagTextCache[entry.id] = owned.prefix(3).joined(separator: ", ") + " (+\(owned.count - 3))"
            }
        }
    }
    
    private func updateSelection() {
        guard let tableView = tableView else { return }
        var indexes = IndexSet()
        for (index, entry) in entries.enumerated() {
            if selectedIDs.contains(entry.id) {
                indexes.insert(index)
            }
        }
        isProgrammaticSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        isProgrammaticSelection = false
    }
    
    private func updateSortIndicators() {
        guard let tableView = tableView else { return }
        let key: String
        switch sortColumn {
        case .fileName: key = "name"
        case .fileSize: key = "size"
        case .ckey: key = "ckey"
        }
        for col in tableView.tableColumns {
            if col.identifier.rawValue == key {
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: sortAscending, comparator: { _, _ in .orderedSame })
            } else {
                col.sortDescriptorPrototype = NSSortDescriptor(key: col.identifier.rawValue, ascending: true, comparator: { _, _ in .orderedSame })
            }
        }
    }
    
    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        onDoubleClick?(entries[row])
    }
    
    @objc private func handleViewDetails(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? InstallManifestEntry else { return }
        onDoubleClick?(entry)
    }
    
    @objc private func handleExport(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? InstallManifestEntry else { return }
        onExport?(entry)
    }
    
    @objc private func handleCopyPath(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? InstallManifestEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.fileName, forType: .string)
    }
}

extension InstallManifestTableViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < entries.count else { return }
        
        let entry = entries[clickedRow]
        
        let viewItem = NSMenuItem(title: L("view_details"), action: #selector(handleViewDetails(_:)), keyEquivalent: "")
        viewItem.target = self
        viewItem.representedObject = entry
        menu.addItem(viewItem)
        
        if onExport != nil {
            let exportItem = NSMenuItem(title: L("export"), action: #selector(handleExport(_:)), keyEquivalent: "")
            exportItem.target = self
            exportItem.representedObject = entry
            menu.addItem(exportItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let copyItem = NSMenuItem(title: L("copy_path"), action: #selector(handleCopyPath(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = entry
        menu.addItem(copyItem)
    }
}

extension InstallManifestTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }
}

extension InstallManifestTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < entries.count else { return nil }
        let entry = entries[row]
        let colID = tableColumn?.identifier.rawValue ?? ""
        let cellID = NSUserInterfaceItemIdentifier("cell-\(colID)")
        var cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellID
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell?.textField = text
            cell?.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                text.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4)
            ])
        }
        
        switch colID {
        case "name":
            cell?.textField?.stringValue = entry.fileName
            cell?.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        case "size":
            cell?.textField?.stringValue = entry.formattedSize
            cell?.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        case "ckey":
            cell?.textField?.stringValue = entry.ckey
            cell?.textField?.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            cell?.textField?.textColor = .secondaryLabelColor
        case "tags":
            cell?.textField?.stringValue = tagTextCache[entry.id] ?? ""
            cell?.textField?.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        default:
            break
        }
        
        return cell
    }
    
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        let column: InstallManifestView.SortColumn
        switch descriptor.key {
        case "size": column = .fileSize
        case "ckey": column = .ckey
        default: column = .fileName
        }
        onSort?(column, descriptor.ascending)
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        guard let tv = notification.object as? NSTableView else { return }
        var ids = Set<String>()
        for index in tv.selectedRowIndexes {
            if index < entries.count {
                ids.insert(entries[index].id)
            }
        }
        onSelect?(ids)
    }
}

struct InstallManifestTableView: NSViewControllerRepresentable {
    var entries: [InstallManifestEntry]
    var tags: [InstallManifestTag]
    var selectedIDs: Set<String>
    var sortColumn: InstallManifestView.SortColumn
    var sortAscending: Bool
    var onSelect: ((Set<String>) -> Void)?
    var onDoubleClick: ((InstallManifestEntry) -> Void)?
    var onExport: ((InstallManifestEntry) -> Void)?
    var onSort: ((InstallManifestView.SortColumn, Bool) -> Void)?
    
    func makeNSViewController(context: Context) -> InstallManifestTableViewController {
        let vc = InstallManifestTableViewController()
        _ = vc.view
        vc.reload(entries: entries, tags: tags, selectedIDs: selectedIDs, sortColumn: sortColumn, sortAscending: sortAscending)
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onExport = onExport
        vc.onSort = onSort
        return vc
    }
    
    func updateNSViewController(_ vc: InstallManifestTableViewController, context: Context) {
        guard vc.isViewLoaded else { return }
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onExport = onExport
        vc.onSort = onSort
        vc.reload(entries: entries, tags: tags, selectedIDs: selectedIDs, sortColumn: sortColumn, sortAscending: sortAscending)
    }
}
