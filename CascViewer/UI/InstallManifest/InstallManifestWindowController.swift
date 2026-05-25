import SwiftUI
import AppKit

@MainActor
class InstallManifestWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [InstallManifestWindowController] = []
    private static let lock = NSLock()

    static func closeAll() {
        Self.lock.lock()
        let controllersToClose = Self.controllers
        Self.controllers.removeAll()
        Self.lock.unlock()
        for controller in controllersToClose {
            controller.window?.close()
        }
    }

    private static func createWindow(tags: [InstallManifestTag], entries: [InstallManifestEntry], storageService: CASCStorageService?) -> (NSWindow, InstallManifestWindowController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("install_manifest_title")
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName("CascViewerInstallManifestWindow")
        window.isRestorable = false
        window.center()

        let hostingView = NSHostingView(rootView:
            InstallManifestView(tags: tags, entries: entries, storageService: storageService)
                .frame(minWidth: 600, minHeight: 400)
        )
        window.contentView = hostingView

        let controller = InstallManifestWindowController(window: window)
        window.delegate = controller
        return (window, controller)
    }

    static func show(tags: [InstallManifestTag], entries: [InstallManifestEntry], storageService: CASCStorageService?) {
        let (window, controller) = createWindow(tags: tags, entries: entries, storageService: storageService)
        window.makeKeyAndOrderFront(nil)
        Self.lock.lock()
        Self.controllers.append(controller)
        Self.lock.unlock()
    }

    static func showInBackground(tags: [InstallManifestTag], entries: [InstallManifestEntry], storageService: CASCStorageService?) {
        let (window, controller) = createWindow(tags: tags, entries: entries, storageService: storageService)
        window.orderFront(nil)
        Self.lock.lock()
        Self.controllers.append(controller)
        Self.lock.unlock()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window?.delegate = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.lock.lock()
            Self.controllers.removeAll { $0 === self }
            Self.lock.unlock()
        }
    }
}
