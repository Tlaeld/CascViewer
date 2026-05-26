import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only create one main window; ignore system restoration.
        guard mainWindow == nil else { return }
        createMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let mainWindow = NSApp.windows.first(where: { $0.frameAutosaveName == "CascViewerMainWindow" }) {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            createMainWindow()
        }
        return false
    }

    func createMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("app_name")
        window.minSize = NSSize(width: 800, height: 600)
        window.setFrameAutosaveName("CascViewerMainWindow")
        window.isRestorable = false
        window.center()
        window.delegate = self

        let hostingView = NSHostingView(rootView: MainWindowView())
        window.contentView = hostingView

        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }

        self.mainWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == mainWindow {
            window.delegate = nil
            mainWindow = nil
            // Close auxiliary windows first before tearing down the main window's
            // SwiftUI state to avoid EXC_BAD_ACCESS in _NSWindowTransformAnimation
            // when aux windows still reference AppState during close animation.
            SearchWindowController.closeWindow()
            OnlineStorageWindowController.closeWindow()
            InstallManifestWindowController.closeAll()
            // Delay contentView cleanup to the next runloop iteration so the window
            // close animation (and any retained blocks from SwiftUI/AppKit) finish
            // before the view hierarchy is torn down.
            DispatchQueue.main.async { [weak window] in
                window?.contentView = nil
            }
        }
    }
}

@main
struct CascViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(before: .newItem) {
                Button(L("new_window")) {
                    appDelegate.createMainWindow()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
