import SwiftUI
import AppKit
import CascBridge

// MARK: - SwiftUI Entry

struct FileListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let storage = appState.currentStorage {
                FileListContent(storage: storage, appState: appState)
            } else {
                EmptyStateView()
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.6))
            Text(L("no_storage_open"))
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Content

struct FileListContent: View {
    @ObservedObject var storage: CASCStorageService
    @ObservedObject var appState: AppState
    @State private var extractEntries: [CASCFileEntry] = []
    @State private var showingExtractSheet = false
    @State private var pendingOpenNode: DirectoryNode? = nil
    @State private var showingDownloadConfirm = false
    @State private var activeExtractService: CASCExtractService? = nil
    @State private var displayedItems: [DirectoryNode] = []

    private func rebuildDisplayedItems() {
        let newItems = storage.currentChildren
        // Avoid redundant SwiftUI updates if the content is identical
        if newItems.count != displayedItems.count || zip(newItems, displayedItems).contains(where: { $0.id != $1.id }) {
            displayedItems = newItems
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            FileTableView(
                items: displayedItems,
                onSelect: { path in
                    appState.selectedPath = path
                },
                onDoubleClick: { path in
                    storage.navigate(to: path)
                },
                onOpenFile: { node in
                    if node.isLocal {
                        Task {
                            await openFile(node: node)
                        }
                    } else {
                        pendingOpenNode = node
                        showingDownloadConfirm = true
                    }
                },
                onExtract: { nodes in
                    extractEntries = nodes.flatMap { node -> [CASCFileEntry] in
                        if node.children != nil {
                            return storage.entriesUnder(path: node.path)
                        } else {
                            return storage.entry(forPath: node.path).map { [$0] } ?? []
                        }
                    }
                    showingExtractSheet = !extractEntries.isEmpty
                }
            )
            .frame(maxHeight: .infinity)
        }
        .alert(L("download_required_title"), isPresented: $showingDownloadConfirm, presenting: pendingOpenNode) { node in
            Button(L("download_and_open"), role: .none) {
                Task {
                    await openFile(node: node)
                }
            }
            Button(L("cancel"), role: .cancel) { }
        } message: { node in
            Text(L("download_required_message", node.name, node.formattedSize))
        }
        .onAppear {
            rebuildDisplayedItems()
        }
        .onChange(of: storage.currentPath) { _ in
            appState.selectedPath = ""
        }
        .onChange(of: storage.currentChildren) { _ in
            rebuildDisplayedItems()
        }
        .onDisappear {
            activeExtractService?.cancel()
        }
        .sheet(isPresented: $showingExtractSheet) {
            ExtractDialogView(entries: extractEntries) { destination, preserveStructure, overwriteExisting, openAfterExtract in
                Task {
                    await performExtraction(to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting, openAfterExtract: openAfterExtract)
                }
            }
        }
        .overlay {
            if let service = activeExtractService, service.isExtracting {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text(L("downloading_file", service.currentFile))
                            .font(.headline)
                            .foregroundColor(.primary)
                        ProgressView(value: service.progress)
                            .frame(width: 280)
                        Button(L("cancel")) {
                            service.cancel()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .frame(width: 340)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 20)
                }
                .onReceive(service.objectWillChange) { _ in }
            }
        }
    }

    @MainActor
    private func openFile(node: DirectoryNode) async {
        guard let storageService = appState.currentStorage else { return }
        guard let entry = storageService.entry(forPath: node.path) else { return }

        // Use a UUID-based sub-directory to avoid collisions between concurrent opens
        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CascViewer/Open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch {
            appState.errorMessage = L("create_temp_dir_failed", error.localizedDescription)
            await MainActor.run { activeExtractService = nil }
            return
        }

        let safeName = entry.name
            .components(separatedBy: "/")
            .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
            .joined(separator: "_")
        let destURL = sessionDir.appendingPathComponent(safeName)

        let service = CASCExtractService(storage: storageService.handle)
        activeExtractService = service
        let result = await service.extract(entries: [entry], to: sessionDir, preserveStructure: false)
        activeExtractService = nil

        // Schedule cleanup regardless of outcome
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            try? FileManager.default.removeItem(at: sessionDir)
        }

        if result.wasCancelled {
            return
        } else if result.failedFiles.isEmpty {
            let isImage = safeName.lowercased().hasSuffix(".blp") || safeName.lowercased().hasSuffix(".dds")
            if isImage, let data = try? Data(contentsOf: destURL) {
                openImageViewerWindow(fileName: safeName, imageData: data)
            } else {
                NSWorkspace.shared.open(destURL)
            }
        } else {
            await MainActor.run {
                let reason = result.failedFiles.first?.error.localizedDescription ?? L("unknown_error")
                appState.errorMessage = L("open_failed", safeName, reason)
            }
        }
    }

    @MainActor
    private func performExtraction(to destination: URL, preserveStructure: Bool, overwriteExisting: Bool, openAfterExtract: Bool) async {
        guard let storageService = appState.currentStorage else { return }
        let extractService = CASCExtractService(storage: storageService.handle)
        activeExtractService = extractService
        let result = await extractService.extract(entries: extractEntries, to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting)
        activeExtractService = nil
        if result.failedFiles.isEmpty {
            appState.errorMessage = L("extract_success", result.successCount)
            if openAfterExtract {
                NSWorkspace.shared.open(destination)
            }
        } else {
            let failedList = result.failedFiles.prefix(10).map {
                let reason = $0.error.localizedDescription
                return "\($0.path)\n  ↳ \(reason)"
            }.joined(separator: "\n")
            let more = result.failedFiles.count > 10 ? "\n... \(result.failedFiles.count - 10) more" : ""
            appState.errorMessage = L("extract_partial", result.successCount, result.failedFiles.count) + "\n\n" + failedList + more
        }
    }

    @ViewBuilder
    private var pathBar: some View {
        HStack(spacing: 6) {
            Button(action: { storage.navigate(to: "") }) {
                Image(systemName: "house").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(L("root"))

            if !storage.currentPath.isEmpty {
                Button(action: {
                    let path = storage.currentPath
                    if let lastSlash = path.lastIndex(of: "/") {
                        storage.navigate(to: String(path[..<lastSlash]))
                    } else {
                        storage.navigate(to: "")
                    }
                }) {
                    Image(systemName: "arrow.up").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(L("parent_directory"))

                let components = storage.currentPath.split(separator: "/", omittingEmptySubsequences: true)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Text("›").font(.system(size: 10)).foregroundColor(.secondary)
                    Button(action: {
                        storage.navigate(to: components[0...index].joined(separator: "/"))
                    }) {
                        Text(String(component)).font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .transaction { $0.animation = nil }
    }

}

// MARK: - NSTableView Bridge (fast flat list, no tree indexing overhead)

@MainActor
final class FileTableViewController: NSViewController {
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?
    private var emptyStateLabel: NSTextField?

    var items: [DirectoryNode] = []
    private var unsortedItems: [DirectoryNode] = []
    private var sortTask: Task<Void, Never>? = nil
    private var lastSelectedPaths: Set<String> = []
    var onSelect: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var onOpenFile: ((DirectoryNode) -> Void)?
    var onExtract: (([DirectoryNode]) -> Void)?

    deinit {
        sortTask?.cancel()
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = NSTableView()
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = NSColor.controlBackgroundColor

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = L("name_column")
        nameCol.width = 300
        nameCol.minWidth = 100
        nameCol.resizingMask = [.autoresizingMask, .userResizingMask]
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(nameCol)

        let pathCol = NSTableColumn(identifier: .init("path"))
        pathCol.title = L("path_column")
        pathCol.width = 300
        pathCol.minWidth = 80
        pathCol.resizingMask = [.autoresizingMask, .userResizingMask]
        pathCol.sortDescriptorPrototype = NSSortDescriptor(key: "path", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(pathCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = L("size_column")
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.resizingMask = .userResizingMask
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(sizeCol)

        let typeCol = NSTableColumn(identifier: .init("type"))
        typeCol.title = L("type_column")
        typeCol.width = 60
        typeCol.minWidth = 50
        typeCol.resizingMask = .userResizingMask
        typeCol.sortDescriptorPrototype = NSSortDescriptor(key: "type", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(typeCol)

        let localCol = NSTableColumn(identifier: .init("local"))
        localCol.title = L("local_column")
        localCol.width = 60
        localCol.minWidth = 50
        localCol.resizingMask = .userResizingMask
        localCol.sortDescriptorPrototype = NSSortDescriptor(key: "local", ascending: true, comparator: { _, _ in .orderedSame })
        tableView.addTableColumn(localCol)

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

        // Default sort: name ascending (directories first via applySorting)
        tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        // Empty state label
        let emptyStateLabel = NSTextField(labelWithString: L("folder_empty"))
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true
        view.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        self.scrollView = scrollView
        self.tableView = tableView
        self.emptyStateLabel = emptyStateLabel
    }

    func reload(items: [DirectoryNode]) {
        self.unsortedItems = items
        applySorting()
    }

    private func applySorting() {
        sortTask?.cancel()
        guard let tableView = tableView as NSTableView? else { return }
        guard let sortDescriptor = tableView.sortDescriptors.first else {
            self.items = unsortedItems
            reloadTable()
            return
        }

        let ascending = sortDescriptor.ascending
        let key = sortDescriptor.key
        let items = unsortedItems
        sortTask = Task { @MainActor [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                return items.sorted { a, b in
                    let aDir = a.children != nil
                    let bDir = b.children != nil
                    if aDir != bDir { return aDir && !bDir }
                    switch key {
                    case "name":
                        return ascending ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                                         : a.name.localizedStandardCompare(b.name) == .orderedDescending
                    case "path":
                        return ascending ? a.path.localizedStandardCompare(b.path) == .orderedAscending
                                         : a.path.localizedStandardCompare(b.path) == .orderedDescending
                    case "size":
                        return ascending ? a.size < b.size : a.size > b.size
                    case "type":
                        return ascending ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                                         : a.name.localizedStandardCompare(b.name) == .orderedDescending
                    case "local":
                        return ascending ? !a.isLocal && b.isLocal : a.isLocal && !b.isLocal
                    default:
                        return false
                    }
                }
            }.value
            guard let self = self, !Task.isCancelled else { return }
            // Preserve selection before replacing items
            let selectedPaths = tableView.selectedRowIndexes.compactMap { idx -> String? in
                idx < self.items.count ? self.items[idx].path : nil
            }
            self.lastSelectedPaths = Set(selectedPaths)
            self.items = sorted
            self.reloadTable()
        }
    }

    private func reloadTable() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let tableView = tableView as NSTableView? else { return }
            guard let scrollView = scrollView as NSScrollView? else { return }
            let scrollRow = tableView.rows(in: scrollView.contentView.visibleRect).location
            self.updatePathColumnVisibility()
            tableView.reloadData()
            self.updateEmptyState()
            self.view.needsLayout = true

            // Restore selection if the same paths still exist
            if !self.lastSelectedPaths.isEmpty {
                var indexes = IndexSet()
                for (idx, item) in self.items.enumerated() {
                    if self.lastSelectedPaths.contains(item.path) {
                        indexes.insert(idx)
                    }
                }
                if !indexes.isEmpty {
                    tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                    if let first = indexes.first {
                        tableView.scrollRowToVisible(first)
                    }
                }
                self.lastSelectedPaths.removeAll()
            } else if scrollRow >= 0, scrollRow < self.items.count {
                tableView.scrollRowToVisible(scrollRow)
            }
        }
    }

    private func updateEmptyState() {
        guard let emptyStateLabel = emptyStateLabel as NSTextField? else { return }
        emptyStateLabel.isHidden = !items.isEmpty
    }

    private func updatePathColumnVisibility() {
        guard let tableView = tableView as NSTableView? else { return }
        guard let pathCol = tableView.tableColumns.first(where: { $0.identifier.rawValue == "path" }) else { return }
        let shouldShow: Bool
        if items.isEmpty {
            shouldShow = true
        } else {
            let parents = Set(items.map { ($0.path as NSString).deletingLastPathComponent })
            shouldShow = parents.count > 1
        }
        let isVisible = tableView.tableColumns.contains(pathCol)
        if shouldShow && !isVisible {
            tableView.addTableColumn(pathCol)
        } else if !shouldShow && isVisible {
            tableView.removeTableColumn(pathCol)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let tableView = tableView as NSTableView? else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 36, // Return
           let firstRow = tableView.selectedRowIndexes.first,
           firstRow >= 0, firstRow < items.count {
            let item = items[firstRow]
            if item.children != nil {
                onDoubleClick?(item.path)
            } else {
                onOpenFile?(item)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scrollView = scrollView as NSScrollView? else { return }
        guard let tableView = tableView as NSTableView? else { return }
        let visibleBounds = scrollView.contentView.bounds
        guard visibleBounds.width > 0 else { return }
        let contentHeight = CGFloat(items.count) * tableView.rowHeight + tableView.intercellSpacing.height * CGFloat(max(items.count - 1, 0))
        let targetHeight = visibleBounds.height > 0 ? max(contentHeight, visibleBounds.height) : contentHeight
        tableView.setFrameSize(NSSize(width: visibleBounds.width, height: targetHeight))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func handleDoubleClick() {
        guard let tableView = tableView as NSTableView? else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.children != nil {
            onDoubleClick?(item.path)
        } else {
            onOpenFile?(item)
        }
    }
}

extension FileTableViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView = tableView as NSTableView? else { return }
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < items.count else { return }

        let selectedRows = tableView.selectedRowIndexes
        let targetRows = selectedRows.contains(clickedRow) ? selectedRows : IndexSet(integer: clickedRow)
        let targetItems = targetRows.compactMap { $0 < items.count ? items[$0] : nil }
        guard !targetItems.isEmpty else { return }

        let isSingleDirectory = targetItems.count == 1 && targetItems[0].children != nil

        if isSingleDirectory {
            let openItem = NSMenuItem(title: L("open"), action: #selector(handleMenuOpen(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = targetItems
            menu.addItem(openItem)
        }

        let extractTitle = targetItems.count == 1 ? L("extract") : L("extract_title", targetItems.count)
        let extractItem = NSMenuItem(title: extractTitle, action: #selector(handleMenuExtract(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = targetItems
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        let copyPathItem = NSMenuItem(title: L("copy_path"), action: #selector(handleMenuCopyPath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.representedObject = targetItems
        menu.addItem(copyPathItem)
    }

    @objc private func handleMenuOpen(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [DirectoryNode], let first = items.first else { return }
        onDoubleClick?(first.path)
    }

    @objc private func handleMenuExtract(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [DirectoryNode] else { return }
        onExtract?(items)
    }

    @objc private func handleMenuCopyPath(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [DirectoryNode] else { return }
        let paths = items.map { $0.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }
}

extension FileTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }
}

extension FileTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let item = items[row]
        let cellID = NSUserInterfaceItemIdentifier("cell-\(tableColumn?.identifier.rawValue ?? "")")
        var cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView

        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellID

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell?.textField = text
            cell?.addSubview(text)

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell?.imageView = icon
            cell?.addSubview(icon)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                text.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4)
            ])
        }

        let colID = tableColumn?.identifier.rawValue ?? ""
        switch colID {
        case "name":
            cell?.textField?.stringValue = item.name
            cell?.textField?.textColor = .labelColor
            cell?.imageView?.image = NSImage(systemSymbolName: item.iconName, accessibilityDescription: nil)
            cell?.imageView?.contentTintColor = item.children != nil ? .controlAccentColor : .secondaryLabelColor
            cell?.imageView?.isHidden = false
            // Remote indicator: subtle opacity instead of "* " prefix
            if AppSettings.shared.showRemoteMarkers && !item.isLocal {
                cell?.textField?.textColor = .systemRed
            }
        case "path":
            cell?.textField?.stringValue = item.path
            cell?.imageView?.isHidden = true
        case "size":
            cell?.textField?.stringValue = item.formattedSize
            cell?.imageView?.isHidden = true
        case "type":
            cell?.textField?.stringValue = item.children != nil ? L("folder") : L("file")
            cell?.imageView?.isHidden = true
        case "local":
            cell?.textField?.stringValue = item.isLocal ? L("local_yes") : L("local_no")
            cell?.textField?.textColor = item.isLocal ? .systemGreen : .systemOrange
            cell?.imageView?.isHidden = true
        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySorting()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        let row = tv.selectedRow
        guard row >= 0, row < items.count else { return }
        onSelect?(items[row].path)
    }
}

struct FileTableView: NSViewControllerRepresentable {
    var items: [DirectoryNode]
    var onSelect: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var onOpenFile: ((DirectoryNode) -> Void)?
    var onExtract: (([DirectoryNode]) -> Void)?

    func makeNSViewController(context: Context) -> FileTableViewController {
        let vc = FileTableViewController()
        _ = vc.view
        vc.reload(items: items)
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onOpenFile = onOpenFile
        vc.onExtract = onExtract
        return vc
    }

    func updateNSViewController(_ vc: FileTableViewController, context: Context) {
        guard vc.isViewLoaded else { return }
        if vc.items.count != items.count || zip(vc.items, items).contains(where: { $0.id != $1.id }) {
            vc.reload(items: items)
        }
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onOpenFile = onOpenFile
        vc.onExtract = onExtract
    }
}
