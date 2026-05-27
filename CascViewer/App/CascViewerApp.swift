import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var mainWindow: NSWindow?
    // Strong retain the window during the close sequence to prevent premature
    // deallocation while SwiftUI internal autorelease pools still hold refs.
    private var windowRetainer: NSWindow?

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
        // Disable the window close animation to prevent EXC_BAD_ACCESS in
        // _NSWindowTransformAnimation when SwiftUI tears down its state while
        // AppKit animation blocks still retain internal pointers.
        window.animationBehavior = .none
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
        guard let window = notification.object as? NSWindow, window == mainWindow else { return }
        // Close auxiliary windows before the main window is deallocated.
        SearchWindowController.closeWindow()
        OnlineStorageWindowController.closeWindow()
        InstallManifestWindowController.closeAll()
        // Retain the window during the close sequence. SwiftUI internally
        // autoreleases the NSWindow in some code paths; if the window is
        // deallocated (isReleasedWhenClosed) before the pool drains, the
        // pool tries to release a zombie NSKVONotifying_NSWindow.
        windowRetainer = window
        mainWindow = nil
    }

    func windowDidClose(_ notification: Notification) {
        // Release the strong retain after AppKit has finished the close
        // sequence and all internal autorelease pools have been drained.
        if let window = notification.object as? NSWindow, window === windowRetainer {
            windowRetainer = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
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
