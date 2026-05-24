import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only create one main window; ignore system restoration.
        guard mainWindow == nil else { return }
        createMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
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

        let hostingView = NSHostingView(rootView: MainWindowView())
        window.contentView = hostingView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.mainWindow = window
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
