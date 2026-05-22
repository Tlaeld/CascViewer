import SwiftUI
import AppKit

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
