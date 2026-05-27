import SwiftUI
import AppKit

@MainActor
class SearchWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SearchWindowController?
    private static let lock = NSLock()

    static func show(appState: AppState) {
        lock.lock()
        defer { lock.unlock() }
        // Close any existing window to avoid retaining a stale AppState from a
        // previously closed main window.
        shared?.window?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("advanced_search")
        window.minSize = NSSize(width: 900, height: 400)
        window.setFrameAutosaveName("CascViewerSearchWindow")
        window.isRestorable = false
        window.center()

        let hostingView = NSHostingView(rootView: SearchPanelView(appState: appState).frame(minWidth: 700, minHeight: 400))
        window.contentView = hostingView

        let controller = SearchWindowController(window: window)
        window.delegate = controller
        shared = controller
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    static func closeWindow() {
        shared?.window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Do NOT set window?.contentView = nil or window?.delegate = nil here.
        // AppKit handles window lifecycle automatically; manual cleanup races
        // with internal KVO teardown and causes double-release crashes.
        SearchWindowController.lock.lock()
        Self.shared = nil
        SearchWindowController.lock.unlock()
    }
}
