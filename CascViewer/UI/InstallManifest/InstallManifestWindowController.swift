import SwiftUI
import AppKit

class InstallManifestWindowController: NSWindowController {
    static func show(tags: [InstallManifestTag], entries: [InstallManifestEntry], storageService: CASCStorageService?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("install_manifest_title")
        window.minSize = NSSize(width: 600, height: 400)
        window.center()

        let hostingView = NSHostingView(rootView:
            InstallManifestView(tags: tags, entries: entries, storageService: storageService)
                .frame(minWidth: 600, minHeight: 400)
        )
        window.contentView = hostingView

        let controller = InstallManifestWindowController(window: window)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
