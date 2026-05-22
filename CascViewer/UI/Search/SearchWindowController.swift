import SwiftUI
import AppKit

@MainActor
class SearchWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SearchWindowController?
    private static let lock = NSLock()

    static func show(appState: AppState) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("advanced_search")
        window.minSize = NSSize(width: 900, height: 400)
        window.center()

        let hostingView = NSHostingView(rootView: SearchPanelView(appState: appState).frame(minWidth: 700, minHeight: 400))
        window.contentView = hostingView

        let controller = SearchWindowController(window: window)
        window.delegate = controller
        shared = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closeWindow() {
        shared?.window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        SearchWindowController.lock.lock()
        Self.shared = nil
        SearchWindowController.lock.unlock()
    }
}
