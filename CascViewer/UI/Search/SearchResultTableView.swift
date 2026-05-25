import SwiftUI
import AppKit

@MainActor
final class SearchResultTableViewController: NSViewController {
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?

    var matches: [SearchMatch] = []
    var selectedMatchId: String? = nil {
        didSet {
            guard selectedMatchId != oldValue else { return }
            updateSelection()
        }
    }
    var searchMode: SearchMode = .filename
    var onSelect: ((SearchMatch) -> Void)?
    var onDoubleClick: ((SearchMatch) -> Void)?
    var onCopyPath: ((String) -> Void)?
    var onOpenFile: ((SearchMatch) -> Void)?
    var onExtract: ((SearchMatch) -> Void)?

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
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        tableView.backgroundColor = NSColor.controlBackgroundColor
        tableView.rowHeight = 36

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = L("name_column")
        nameCol.width = 400
        nameCol.minWidth = 200
        nameCol.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(nameCol)

        let pathCol = NSTableColumn(identifier: .init("path"))
        pathCol.title = L("path_column")
        pathCol.width = 300
        pathCol.minWidth = 150
        pathCol.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(pathCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = L("size_column")
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.maxWidth = 120
        sizeCol.resizingMask = .userResizingMask
        tableView.addTableColumn(sizeCol)

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

        self.scrollView = scrollView
        self.tableView = tableView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scrollView = scrollView else { return }
        guard let tableView = tableView else { return }
        let newWidth = scrollView.bounds.width
        var frame = tableView.frame
        if abs(frame.size.width - newWidth) > 0.5 {
            frame.size.width = newWidth
            tableView.frame = frame
        }
    }

    func reload(matches: [SearchMatch], mode: SearchMode) {
        self.matches = matches
        self.searchMode = mode
        guard let tableView = tableView else { return }
        tableView.reloadData()
        updateSelection()
        // Ensure width matches container after data reload
        guard let scrollView = scrollView else { return }
        var frame = tableView.frame
        frame.size.width = scrollView.bounds.width
        tableView.frame = frame
    }

    private func updateSelection() {
        guard let tableView = tableView else { return }
        if let id = selectedMatchId, let index = matches.firstIndex(where: { $0.id == id }) {
            if tableView.selectedRow != index {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
            }
        } else {
            if tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
        }
    }

    @objc private func handleDoubleClick() {
        guard let tableView = tableView else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < matches.count else { return }
        onDoubleClick?(matches[row])
    }
}

extension SearchResultTableViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView = tableView else { return }
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < matches.count else { return }

        let selectedRows = tableView.selectedRowIndexes
        let targetRows = selectedRows.contains(clickedRow) ? selectedRows : IndexSet(integer: clickedRow)
        let targetMatches = targetRows.compactMap { $0 < matches.count ? matches[$0] : nil }
        guard !targetMatches.isEmpty else { return }

        let goItem = NSMenuItem(title: L("search_go_to_location"), action: #selector(handleMenuGoTo(_:)), keyEquivalent: "")
        goItem.target = self
        goItem.representedObject = targetMatches
        menu.addItem(goItem)

        let openItem = NSMenuItem(title: L("open"), action: #selector(handleMenuOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = targetMatches
        menu.addItem(openItem)

        let extractTitle = targetMatches.count == 1 ? L("extract") : L("extract_title", targetMatches.count)
        let extractItem = NSMenuItem(title: extractTitle, action: #selector(handleMenuExtract(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = targetMatches
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: L("copy_path"), action: #selector(handleMenuCopyPath(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = targetMatches
        menu.addItem(copyItem)
    }

    @objc private func handleMenuGoTo(_ sender: NSMenuItem) {
        guard let targetMatches = sender.representedObject as? [SearchMatch], let first = targetMatches.first else { return }
        onDoubleClick?(first)
    }

    @objc private func handleMenuOpen(_ sender: NSMenuItem) {
        guard let targetMatches = sender.representedObject as? [SearchMatch], let first = targetMatches.first else { return }
        onOpenFile?(first)
    }

    @objc private func handleMenuExtract(_ sender: NSMenuItem) {
        guard let targetMatches = sender.representedObject as? [SearchMatch], let first = targetMatches.first else { return }
        onExtract?(first)
    }

    @objc private func handleMenuCopyPath(_ sender: NSMenuItem) {
        guard let targetMatches = sender.representedObject as? [SearchMatch] else { return }
        let paths = targetMatches.map { $0.entry.fullPath.replacingOccurrences(of: "\\", with: "/") }.joined(separator: "\n")
        onCopyPath?(paths)
    }
}

extension SearchResultTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return matches.count
    }
}

extension SearchResultTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < matches.count else { return nil }
        let match = matches[row]
        let colID = tableColumn?.identifier.rawValue ?? ""
        let cellID = NSUserInterfaceItemIdentifier("search-cell-\(colID)")
        var cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView

        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellID

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.maximumNumberOfLines = 1
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
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                text.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4)
            ])
        }

        switch colID {
        case "name":
            cell?.textField?.stringValue = match.entry.name
            cell?.textField?.textColor = .labelColor
            let iconName = match.entry.isDirectory ? "folder" : "doc"
            cell?.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            cell?.imageView?.contentTintColor = match.entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            cell?.imageView?.isHidden = false
            if AppSettings.shared.showRemoteMarkers && !match.entry.isLocal {
                cell?.textField?.textColor = .systemRed
            }
        case "path":
            cell?.textField?.stringValue = match.entry.normalizedPath
            cell?.textField?.textColor = .secondaryLabelColor
            cell?.imageView?.isHidden = true
        case "size":
            cell?.textField?.stringValue = match.entry.formattedSize
            cell?.textField?.textColor = .secondaryLabelColor
            cell?.imageView?.isHidden = true
        default:
            break
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        let row = tv.selectedRow
        guard row >= 0, row < matches.count else { return }
        onSelect?(matches[row])
    }
}

struct SearchResultTableView: NSViewControllerRepresentable {
    var matches: [SearchMatch]
    var searchMode: SearchMode
    var selectedMatchId: String?
    var onSelect: ((SearchMatch) -> Void)?
    var onDoubleClick: ((SearchMatch) -> Void)?
    var onCopyPath: ((String) -> Void)?
    var onOpenFile: ((SearchMatch) -> Void)?
    var onExtract: ((SearchMatch) -> Void)?

    func makeNSViewController(context: Context) -> SearchResultTableViewController {
        let vc = SearchResultTableViewController()
        _ = vc.view
        vc.reload(matches: matches, mode: searchMode)
        vc.selectedMatchId = selectedMatchId
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onCopyPath = onCopyPath
        vc.onOpenFile = onOpenFile
        vc.onExtract = onExtract
        return vc
    }

    func updateNSViewController(_ vc: SearchResultTableViewController, context: Context) {
        guard vc.isViewLoaded else { return }
        // For small datasets, do a full comparison to catch middle-row mutations.
        // For large datasets, use a heuristic to avoid O(n) cost.
        let shouldReload: Bool
        if vc.matches.count != matches.count {
            shouldReload = true
        } else if matches.count < 1000 {
            shouldReload = vc.matches != matches
        } else {
            let firstChanged = vc.matches.first != matches.first
            let lastChanged = vc.matches.last != matches.last
            shouldReload = firstChanged || lastChanged
        }
        if shouldReload {
            vc.reload(matches: matches, mode: searchMode)
        }
        vc.selectedMatchId = selectedMatchId
        vc.searchMode = searchMode
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onCopyPath = onCopyPath
    }
}
