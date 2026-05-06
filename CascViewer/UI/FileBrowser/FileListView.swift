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
                    .frame(maxHeight: .infinity)
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
    @State private var searchTask: Task<Void, Never>? = nil

    private var displayedItems: [DirectoryNode] {
        if appState.isSearchMode {
            return appState.searchResults.map { DirectoryNode(from: $0) }
        }
        return storage.currentChildren
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.isSearchMode {
                searchStatusBar
            } else {
                pathBar
            }
            Divider()
            FileTableView(
                items: displayedItems,
                onSelect: { path in
                    appState.selectedPath = path
                },
                onDoubleClick: { path in
                    if appState.isSearchMode {
                        // In search mode, double-click navigates to the file's parent directory
                        let parentPath = (path as NSString).deletingLastPathComponent
                        appState.isSearchMode = false
                        storage.navigate(to: parentPath)
                        appState.selectedPath = path
                    } else {
                        storage.navigate(to: path)
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
        }
        .onChange(of: storage.currentPath) { _ in
            appState.selectedPath = ""
        }
        .onChange(of: appState.isSearchMode) { newValue in
            if newValue {
                performSearch()
            } else {
                searchTask?.cancel()
                appState.searchResults = []
                appState.isSearching = false
            }
        }
        .sheet(isPresented: $showingExtractSheet) {
            ExtractDialogView(entries: extractEntries) { destination, preserveStructure, _, _ in
                Task {
                    await performExtraction(to: destination, preserveStructure: preserveStructure)
                }
            }
        }
    }

    private func performSearch() {
        guard let storageService = appState.currentStorage else { return }
        searchTask?.cancel()
        appState.isSearching = true
        appState.searchResults = []

        let query = appState.searchQuery
        searchTask = Task {
            let searchService = CASCSearchService(storage: storageService)
            let results = await searchService.search(query: query, in: "", useRegex: false)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                appState.searchResults = results
                appState.isSearching = false
            }
        }
    }

    private func performExtraction(to destination: URL, preserveStructure: Bool) async {
        guard let storageService = appState.currentStorage else { return }
        let extractService = CASCExtractService(storage: storageService.handle)
        let result = await extractService.extract(entries: extractEntries, to: destination, preserveStructure: preserveStructure)
        if result.failedFiles.isEmpty {
            appState.errorMessage = L("extract_success", result.successCount)
        } else {
            let failedList = result.failedFiles.prefix(10).map { $0.path }.joined(separator: "\n")
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

    @ViewBuilder
    private var searchStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.accentColor)
                .font(.system(size: 11))

            Text("\(L("search_status_prefix")) \"\(appState.searchQuery)\"")
                .font(.system(size: 11))
                .lineLimit(1)

            if appState.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }

            Spacer()

            if !appState.isSearching {
                Text("\(appState.searchResults.count) \(L("search_status_results"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(L("cancel")) {
                appState.isSearchMode = false
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .transaction { $0.animation = nil }
    }
}

// MARK: - NSTableView Bridge (fast flat list, no tree indexing overhead)

final class FileTableViewController: NSViewController {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    var items: [DirectoryNode] = []
    var onSelect: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var onExtract: (([DirectoryNode]) -> Void)?

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
        nameCol.title = L("name_column")
        nameCol.width = 300
        nameCol.minWidth = 100
        tableView.addTableColumn(nameCol)

        let pathCol = NSTableColumn(identifier: .init("path"))
        pathCol.title = L("path_column")
        pathCol.width = 300
        tableView.addTableColumn(pathCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = L("size_column")
        sizeCol.width = 80
        tableView.addTableColumn(sizeCol)

        let typeCol = NSTableColumn(identifier: .init("type"))
        typeCol.title = L("type_column")
        typeCol.width = 60
        tableView.addTableColumn(typeCol)

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

    func reload(items: [DirectoryNode]) {
        self.items = items
        // Defer reloadData to next runloop to avoid reentrant NSTableView delegate warnings
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
        }
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onDoubleClick?(items[row].path)
    }
}

extension FileTableViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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
            let showMarkers = AppSettings.shared.showRemoteMarkers
            cell?.textField?.stringValue = (showMarkers && !item.isLocal) ? "* " + item.name : item.name
            cell?.textField?.textColor = (showMarkers && !item.isLocal) ? .systemRed : .labelColor
            let iconName = item.children != nil ? "folder.fill" : "doc"
            cell?.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            cell?.imageView?.contentTintColor = item.children != nil ? .controlAccentColor : .secondaryLabelColor
            cell?.imageView?.isHidden = false
        case "path":
            cell?.textField?.stringValue = item.path
            cell?.imageView?.isHidden = true
        case "size":
            cell?.textField?.stringValue = "—"
            cell?.imageView?.isHidden = true
        case "type":
            cell?.textField?.stringValue = item.children != nil ? L("folder") : L("file")
            cell?.imageView?.isHidden = true
        default:
            break
        }

        return cell
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
    var onExtract: (([DirectoryNode]) -> Void)?

    func makeNSViewController(context: Context) -> FileTableViewController {
        let vc = FileTableViewController()
        _ = vc.view
        vc.reload(items: items)
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
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
        vc.onExtract = onExtract
    }
}
