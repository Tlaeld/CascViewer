import SwiftUI
import AppKit

struct TreeRow: Equatable {
    let node: DirectoryNode
    let depth: Int
    let isExpanded: Bool
    let hasChildren: Bool
}

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let storage = appState.currentStorage {
            FileTreeContent(storage: storage)
        } else {
            VStack(spacing: 0) {
                Text(L("directories"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
                Text(L("open_storage_to_browse"))
                    .foregroundColor(.secondary)
                    .font(.callout)
                    .padding(.top, 20)
                Spacer()
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

struct FileTreeContent: View {
    @ObservedObject var storage: CASCStorageService
    @State private var expandedPaths: Set<String> = []
    @State private var extractEntries: [CASCFileEntry] = []
    @State private var showingExtractSheet = false

    private var displayRows: [TreeRow] {
        func build(path: String, depth: Int) -> [TreeRow] {
            let children = storage.childrenByPath[path, default: []]
            let dirs = children.filter { $0.children != nil }.sorted { $0.name < $1.name }
            var rows: [TreeRow] = []
            for dir in dirs {
                let isExpanded = expandedPaths.contains(dir.path)
                let hasChildren = storage.childrenByPath[dir.path]?.contains(where: { $0.children != nil }) ?? false
                rows.append(TreeRow(node: dir, depth: depth, isExpanded: isExpanded, hasChildren: hasChildren))
                if isExpanded {
                    rows += build(path: dir.path, depth: depth + 1)
                }
            }
            return rows
        }
        return build(path: "", depth: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("directories"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            TreeTableView(
                items: displayRows,
                currentPath: storage.currentPath,
                onSelect: { path in
                    storage.navigate(to: path)
                },
                onToggleExpand: { path in
                    if expandedPaths.contains(path) {
                        expandedPaths.remove(path)
                    } else {
                        expandedPaths.insert(path)
                    }
                },
                onExtract: { path in
                    extractEntries = storage.entriesUnder(path: path)
                    showingExtractSheet = !extractEntries.isEmpty
                }
            )

            Spacer()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showingExtractSheet) {
            ExtractDialogView(entries: extractEntries) { destination, preserveStructure, overwriteExisting, openAfterExtract in
                Task {
                    await performExtraction(to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting, openAfterExtract: openAfterExtract)
                }
            }
        }
        .onChange(of: storage.allEntriesCount) { _ in
            expandedPaths.removeAll()
        }
    }

    private func performExtraction(to destination: URL, preserveStructure: Bool, overwriteExisting: Bool, openAfterExtract: Bool) async {
        let extractService = CASCExtractService(storage: storage.handle)
        let result = await extractService.extract(entries: extractEntries, to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting)
        if result.wasCancelled {
            // Silently ignore cancelled extractions
        } else if result.failedFiles.isEmpty {
            if openAfterExtract {
                NSWorkspace.shared.open(destination)
            }
        } else {
            print("[Extract] \(result.successCount) succeeded, \(result.failedFiles.count) failed")
            for f in result.failedFiles.prefix(5) {
                print("  FAILED: \(f.path) - \(f.error.localizedDescription)")
            }
        }
    }
}

// MARK: - NSTableView Bridge

final class TreeTableViewController: NSViewController {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    var items: [TreeRow] = []
    var currentPath: String = ""
    var onSelect: ((String) -> Void)?
    var onToggleExpand: ((String) -> Void)?
    var onExtract: ((String) -> Void)?
    private var isProgrammaticSelection = false
    private var suppressSelection = false

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowSizeStyle = .small
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.backgroundColor = .clear

        let col = NSTableColumn(identifier: .init("name"))
        col.title = L("name_column")
        col.width = 180
        col.minWidth = 100
        tableView.addTableColumn(col)

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

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }

    func reload(items: [TreeRow], currentPath: String) {
        self.items = items
        self.currentPath = currentPath
        tableView.reloadData()
        selectCurrentPath()
    }

    private func selectCurrentPath() {
        guard let index = items.firstIndex(where: {
            currentPath == $0.node.path
        }) else {
            tableView.deselectAll(nil)
            return
        }
        isProgrammaticSelection = true
        let indexSet = IndexSet(integer: index)
        tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        isProgrammaticSelection = false
    }

    @objc private func toggleExpand(_ sender: NSButton) {
        suppressSelection = true
        let row = sender.tag
        guard row >= 0, row < items.count else {
            suppressSelection = false
            return
        }
        let path = items[row].node.path
        onToggleExpand?(path)
        // Defer clearing until the next event cycle, after SwiftUI has reloaded the tree
        DispatchQueue.main.async { [weak self] in
            self?.suppressSelection = false
        }
    }
}

extension TreeTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }
}

extension TreeTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("treeCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        let rowItem = items[row]
        let baseX = CGFloat(8 + rowItem.depth * 16)
        let cellHeight: CGFloat = 24

        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = identifier

            let expandButton = NSButton()
            expandButton.bezelStyle = .recessed
            expandButton.setButtonType(.momentaryLight)
            expandButton.isBordered = false
            expandButton.target = self
            expandButton.action = #selector(toggleExpand(_:))
            expandButton.font = NSFont.systemFont(ofSize: 10)
            expandButton.tag = row
            expandButton.translatesAutoresizingMaskIntoConstraints = false
            expandButton.identifier = NSUserInterfaceItemIdentifier("expandButton")
            cell?.addSubview(expandButton)

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.identifier = NSUserInterfaceItemIdentifier("icon")
            cell?.imageView = icon
            cell?.addSubview(icon)

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.identifier = NSUserInterfaceItemIdentifier("text")
            cell?.textField = text
            cell?.addSubview(text)

            let expandLeading = expandButton.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: baseX)
            expandLeading.identifier = "expandLeading"
            NSLayoutConstraint.activate([
                expandLeading,
                expandButton.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                expandButton.widthAnchor.constraint(equalToConstant: 16),
                expandButton.heightAnchor.constraint(equalToConstant: 16),

                icon.leadingAnchor.constraint(equalTo: expandButton.trailingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),

                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                text.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -8)
            ])
        }

        // Update expand button position and state
        if let expandButton = cell?.subviews.first(where: { $0.identifier?.rawValue == "expandButton" }) as? NSButton {
            expandButton.tag = row
            expandButton.isHidden = !rowItem.hasChildren
            expandButton.title = rowItem.isExpanded ? "▼" : "▶"
            if let constraint = cell?.constraints.first(where: { $0.identifier == "expandLeading" }) {
                constraint.constant = baseX
            }
        }

        // Update icon
        let icon = cell?.imageView
        icon?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        icon?.contentTintColor = .controlAccentColor

        // Update text
        let showMarkers = AppSettings.shared.showRemoteMarkers
        cell?.textField?.stringValue = (showMarkers && !rowItem.node.isLocal) ? "* " + rowItem.node.name : rowItem.node.name
        cell?.textField?.textColor = (showMarkers && !rowItem.node.isLocal) ? .systemRed : .labelColor

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection, !suppressSelection else { return }
        guard let tv = notification.object as? NSTableView else { return }
        let row = tv.selectedRow
        guard row >= 0 else { return }
        onSelect?(items[row].node.path)
    }
}

extension TreeTableViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }

        let path = items[row].node.path
        let openItem = NSMenuItem(title: L("open"), action: #selector(handleMenuOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = path
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let extractTitle = items[row].node.children != nil ? L("extract_all") : L("extract")
        let extractItem = NSMenuItem(title: extractTitle, action: #selector(handleMenuExtract(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = path
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        let copyPathItem = NSMenuItem(title: L("copy_path"), action: #selector(handleMenuCopyPath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.representedObject = path
        menu.addItem(copyPathItem)
    }

    @objc private func handleMenuOpen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onSelect?(path)
    }

    @objc private func handleMenuExtract(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onExtract?(path)
    }

    @objc private func handleMenuCopyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

struct TreeTableView: NSViewControllerRepresentable {
    var items: [TreeRow]
    var currentPath: String
    var onSelect: ((String) -> Void)?
    var onToggleExpand: ((String) -> Void)?
    var onExtract: ((String) -> Void)?

    func makeNSViewController(context: Context) -> TreeTableViewController {
        let vc = TreeTableViewController()
        _ = vc.view
        vc.reload(items: items, currentPath: currentPath)
        vc.onSelect = onSelect
        vc.onToggleExpand = onToggleExpand
        vc.onExtract = onExtract
        return vc
    }

    func updateNSViewController(_ vc: TreeTableViewController, context: Context) {
        guard vc.isViewLoaded else { return }
        let itemsChanged = vc.items.count != items.count || zip(vc.items, items).contains(where: { $0 != $1 })
        let pathChanged = vc.currentPath != currentPath
        if itemsChanged || pathChanged {
            vc.reload(items: items, currentPath: currentPath)
        }
        vc.onSelect = onSelect
        vc.onToggleExpand = onToggleExpand
        vc.onExtract = onExtract
    }
}
