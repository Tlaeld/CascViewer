import SwiftUI
import AppKit

final class SearchResultTableViewController: NSViewController {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

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
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scrollView = scrollView else { return }
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
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
            self?.updateSelection()
            // Ensure width matches container after data reload
            if let scrollView = self?.scrollView {
                var frame = self?.tableView.frame ?? .zero
                frame.size.width = scrollView.bounds.width
                self?.tableView.frame = frame
            }
        }
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
        let row = tableView.clickedRow
        guard row >= 0, row < matches.count else { return }
        onDoubleClick?(matches[row])
    }
}

extension SearchResultTableViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < matches.count else { return }

        let goItem = NSMenuItem(title: L("search_go_to_location"), action: #selector(handleMenuGoTo(_:)), keyEquivalent: "")
        goItem.target = self
        goItem.representedObject = clickedRow
        menu.addItem(goItem)

        let copyItem = NSMenuItem(title: L("copy_path"), action: #selector(handleMenuCopyPath(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = clickedRow
        menu.addItem(copyItem)
    }

    @objc private func handleMenuGoTo(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, row < matches.count else { return }
        onDoubleClick?(matches[row])
    }

    @objc private func handleMenuCopyPath(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, row < matches.count else { return }
        let path = matches[row].entry.fullPath.replacingOccurrences(of: "\\", with: "/")
        onCopyPath?(path)
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
        case "path":
            let displayPath = match.entry.fullPath.replacingOccurrences(of: "\\", with: "/")
            cell?.textField?.stringValue = displayPath
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

    func makeNSViewController(context: Context) -> SearchResultTableViewController {
        let vc = SearchResultTableViewController()
        _ = vc.view
        vc.reload(matches: matches, mode: searchMode)
        vc.selectedMatchId = selectedMatchId
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onCopyPath = onCopyPath
        return vc
    }

    func updateNSViewController(_ vc: SearchResultTableViewController, context: Context) {
        guard vc.isViewLoaded else { return }
        // Avoid O(n) identity comparison on 50K+ rows.
        // Reload when: count changed, first element changed, or last element changed.
        let countChanged = vc.matches.count != matches.count
        let firstChanged = vc.matches.first != matches.first
        let lastChanged = vc.matches.last != matches.last
        if countChanged || firstChanged || lastChanged {
            vc.reload(matches: matches, mode: searchMode)
        }
        vc.selectedMatchId = selectedMatchId
        vc.searchMode = searchMode
        vc.onSelect = onSelect
        vc.onDoubleClick = onDoubleClick
        vc.onCopyPath = onCopyPath
    }
}
