import SwiftUI
import AppKit

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let storage = appState.currentStorage {
            FileTreeContent(storage: storage) { errorMessage in
                appState.errorMessage = errorMessage
            }
        } else {
            VStack(spacing: 0) {
                Text(L("directories"))
                    .font(DS.Fonts.sectionHeader)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                Divider()
                Text(L("open_storage_to_browse"))
                    .foregroundColor(.secondary)
                    .font(DS.Fonts.body)
                    .padding(.top, 20)
                Spacer()
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }
}

struct FileTreeContent: View {
    @ObservedObject var storage: CASCStorageService
    @StateObject private var expansion = TreeExpansionStore()
    @State private var extractEntries: [CASCFileEntry] = []
    @State private var showingExtractSheet = false
    @State private var activeExtractService: CASCExtractService? = nil
    var onError: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L("directories"))
                .font(DS.Fonts.sectionHeader)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)

            Divider()

            TreeOutlineView(
                generation: storage.entriesGeneration,
                childrenByPath: storage.childrenByPath,
                currentPath: storage.currentPath,
                expansion: expansion,
                onSelect: { path in
                    storage.navigate(to: path)
                },
                onExtract: { path in
                    extractEntries = storage.entriesUnder(path: path)
                    showingExtractSheet = !extractEntries.isEmpty
                }
            )

            Spacer()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .sheet(isPresented: $showingExtractSheet) {
            ExtractDialogView(entries: extractEntries) { destination, preserveStructure, overwriteExisting, openAfterExtract in
                Task {
                    await performExtraction(to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting, openAfterExtract: openAfterExtract)
                }
            }
        }
        .overlay {
            ExtractionOverlay(
                service: activeExtractService,
                titleKey: "extracting_files",
                width: 280,
                showPercentage: false
            )
        }
        .onChange(of: storage.entriesGeneration) { _ in
            // 条目真正重载(open/refresh)才重置展开状态;内存导航不会走到这里。
            expansion.reset()
        }
        .onChange(of: storage.currentPath) { newPath in
            // 自动展开当前路径的祖先链,不清空别处已展开的分支。
            expansion.expandAncestors(of: newPath)
        }
        .onDisappear {
            activeExtractService?.cancel()
        }
    }

    @MainActor
    private func performExtraction(to destination: URL, preserveStructure: Bool, overwriteExisting: Bool, openAfterExtract: Bool) async {
        let extractService = CASCExtractService(storage: storage.handle)
        activeExtractService = extractService
        let result = await extractService.extract(entries: extractEntries, to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting)
        activeExtractService = nil
        if result.wasCancelled {
            // Silently ignore cancelled extractions
        } else if result.failedFiles.isEmpty {
            if openAfterExtract {
                NSWorkspace.shared.open(destination)
            }
        } else {
            let failedList = result.failedFiles.prefix(10).map {
                let reason = $0.error.localizedDescription
                return "\($0.path)\n  ↳ \(reason)"
            }.joined(separator: "\n")
            let more = result.failedFiles.count > 10 ? "\n... \(result.failedFiles.count - 10) more" : ""
            let message = L("extract_partial", result.successCount, result.failedFiles.count) + "\n\n" + failedList + more
            onError(message)
        }
    }
}

// MARK: - NSOutlineView Bridge

@MainActor
final class TreeOutlineViewController: NSViewController {
    private var outlineView: NSOutlineView?
    private var scrollView: NSScrollView?

    /// 数据快照:仅含目录(children != nil),按父路径分组。
    private var dirCache: [String: [DirectoryNode]] = [:]
    private var nodeByPath: [String: DirectoryNode] = [:]
    private(set) var generation: Int = -1
    private var currentPath: String = ""
    /// 已同步到 outlineView 的展开集合,用于差量展开/收起。
    private var appliedExpansion: Set<String> = []

    var expansion: TreeExpansionStore?
    var onSelect: ((String) -> Void)?
    var onExtract: ((String) -> Void)?

    private var isProgrammaticSelection = false
    private var isSyncingExpansion = false

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
        // 不刷实色背景,透出侧栏的 NSVisualEffectView 毛玻璃材质
        scrollView.drawsBackground = false

        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.indentationPerLevel = 16
        outlineView.rowSizeStyle = .small
        outlineView.backgroundColor = .clear

        let col = NSTableColumn(identifier: .init("name"))
        col.title = L("name_column")
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col

        scrollView.documentView = outlineView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        outlineView.dataSource = self
        outlineView.delegate = self

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        self.scrollView = scrollView
        self.outlineView = outlineView
    }

    /// 条目重载(generation 变化)时调用:重建缓存、全量刷新、重新同步展开与选中。
    func reload(generation: Int, childrenByPath: [String: [DirectoryNode]], currentPath: String) {
        var cache: [String: [DirectoryNode]] = [:]
        var byPath: [String: DirectoryNode] = [:]
        for (path, children) in childrenByPath {
            let dirs = children.filter { $0.children != nil }
            cache[path] = dirs
            for dir in dirs {
                byPath[dir.path] = dir
            }
        }
        self.dirCache = cache
        self.nodeByPath = byPath
        self.generation = generation
        self.currentPath = currentPath
        self.appliedExpansion = []
        outlineView?.reloadData()
        applyExpansion()
        selectPath(currentPath)
    }

    /// 把 store 的展开状态差量同步到 outlineView(不触发通知回环)。
    func applyExpansion() {
        guard let outlineView = outlineView, let expansion = expansion else { return }
        let target = expansion.expandedPaths
        let old = appliedExpansion
        guard target != old else { return }
        isSyncingExpansion = true
        for path in old.subtracting(target) {
            if let node = nodeByPath[path] {
                outlineView.collapseItem(node)
            }
        }
        for path in target.subtracting(old) {
            if let node = nodeByPath[path] {
                outlineView.expandItem(node)
            }
        }
        appliedExpansion = target
        isSyncingExpansion = false
    }

    /// 按路径恢复选中(无该路径时清空选中)。
    func selectPath(_ path: String) {
        guard let outlineView = outlineView else { return }
        currentPath = path
        guard let node = nodeByPath[path] else {
            if outlineView.selectedRow >= 0 {
                isProgrammaticSelection = true
                outlineView.deselectAll(nil)
                isProgrammaticSelection = false
            }
            return
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        guard outlineView.selectedRow != row else { return }
        isProgrammaticSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isProgrammaticSelection = false
    }
}

extension TreeOutlineViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DirectoryNode else {
            return dirCache[""]?.count ?? 0
        }
        return dirCache[node.path]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? DirectoryNode else {
            return dirCache[""]![index]
        }
        return dirCache[node.path]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? DirectoryNode else { return false }
        return node.hasChildDirectories
    }
}

extension TreeOutlineViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DirectoryNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("treeCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            let newCell = NSTableCellView()
            newCell.identifier = identifier

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            newCell.imageView = icon
            newCell.addSubview(icon)

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = NSFont.systemFont(ofSize: DS.rowFontSize)
            newCell.textField = text
            newCell.addSubview(text)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Spacing.xs),
                text.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -DS.Spacing.xs)
            ])
            cell = newCell
        }

        cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = DS.NSColors.folderIcon
        cell.textField?.stringValue = node.name
        let remote = AppSettings.shared.showRemoteMarkers && !node.isLocal
        cell.textField?.textColor = remote ? DS.NSColors.remoteFile : DS.NSColors.rowText
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 24
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection, !isSyncingExpansion else { return }
        guard let outlineView = outlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? DirectoryNode else { return }
        onSelect?(node.path)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DirectoryNode else { return }
        appliedExpansion.insert(node.path)
        if !isSyncingExpansion {
            expansion?.expand(node.path)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DirectoryNode else { return }
        appliedExpansion.remove(node.path)
        if !isSyncingExpansion {
            expansion?.collapse(node.path)
        }
    }
}

extension TreeOutlineViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outlineView = outlineView else { return }
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? DirectoryNode else { return }

        let path = node.path
        let openItem = NSMenuItem(title: L("open"), action: #selector(handleMenuOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = path
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let extractItem = NSMenuItem(title: L("extract_all"), action: #selector(handleMenuExtract(_:)), keyEquivalent: "")
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

struct TreeOutlineView: NSViewControllerRepresentable {
    let generation: Int
    let childrenByPath: [String: [DirectoryNode]]
    let currentPath: String
    let expansion: TreeExpansionStore
    var onSelect: ((String) -> Void)?
    var onExtract: ((String) -> Void)?

    func makeNSViewController(context: Context) -> TreeOutlineViewController {
        let vc = TreeOutlineViewController()
        _ = vc.view
        vc.expansion = expansion
        vc.onSelect = onSelect
        vc.onExtract = onExtract
        vc.reload(generation: generation, childrenByPath: childrenByPath, currentPath: currentPath)
        return vc
    }

    func updateNSViewController(_ vc: TreeOutlineViewController, context: Context) {
        guard vc.isViewLoaded else { return }
        vc.expansion = expansion
        vc.onSelect = onSelect
        vc.onExtract = onExtract
        if vc.generation != generation {
            vc.reload(generation: generation, childrenByPath: childrenByPath, currentPath: currentPath)
        } else {
            vc.applyExpansion()
            vc.selectPath(currentPath)
        }
    }
}
