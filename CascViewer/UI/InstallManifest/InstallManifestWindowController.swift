import SwiftUI
import AppKit

@MainActor
class InstallManifestWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [InstallManifestWindowController] = []
    private static let lock = NSLock()

    static func show(tags: [InstallManifestTag], entries: [InstallManifestEntry], storageService: CASCStorageService?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("install_manifest_title")
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName("CascViewerInstallManifestWindow")
        window.center()

        let hostingView = NSHostingView(rootView:
            InstallManifestView(tags: tags, entries: entries, storageService: storageService)
                .frame(minWidth: 600, minHeight: 400)
        )
        window.contentView = hostingView

        let controller = InstallManifestWindowController(window: window)
        window.delegate = controller
        controller.showWindow(nil)
        Self.lock.lock()
        Self.controllers.append(controller)
        Self.lock.unlock()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.lock.lock()
            Self.controllers.removeAll { $0 === self }
            Self.lock.unlock()
        }
    }
}
