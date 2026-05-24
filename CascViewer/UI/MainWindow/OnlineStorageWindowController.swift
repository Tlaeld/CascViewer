import SwiftUI
import AppKit
import CascBridge

@MainActor
class OnlineStorageWindowController: NSWindowController, NSWindowDelegate {
    static var shared: OnlineStorageWindowController?
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("open_online_storage")
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName("CascViewerOnlineStorageWindow")
        window.center()

        let hostingView = NSHostingView(rootView:
            OnlineStorageView(
                onOpen: { product, region in
                    appState.openStorageTask = Task {
                        let shouldProceed = await Self.confirmCacheAction(product: product, region: region)
                        guard shouldProceed else {
                            await MainActor.run { Self.closeWindow() }
                            appState.openStorageTask = nil
                            return
                        }
                        let storage = CascBridge.CascStorageHandle.createLocal()
                        let service = CASCStorageService(storage: storage)
                        await MainActor.run {
                            appState.currentStorage?.close()
                            appState.currentStorage = service
                        }
                        await service.openOnline(product: product, region: region)
                        if service.error != nil {
                            await MainActor.run {
                                appState.errorMessage = service.error?.localizedDescription
                            }
                        }
                        await MainActor.run { Self.closeWindow() }
                        appState.openStorageTask = nil
                    }
                },
                onCancel: {
                    Self.closeWindow()
                }
            )
            .frame(minWidth: 600, minHeight: 400)
        )
        window.contentView = hostingView

        let controller = OnlineStorageWindowController(window: window)
        window.delegate = controller
        shared = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closeWindow() {
        shared?.window?.close()
    }

    /// Checks if a cache already exists for the given product. If it does, presents a modal alert
    /// asking the user whether to reuse the cache, overwrite it, or cancel the operation.
    /// - Returns: `true` if the caller should proceed with opening the storage; `false` if cancelled.
    private static func confirmCacheAction(product: String, region: String) async -> Bool {
        let baseCachePath = AppSettings.shared.cdnCachePath.isEmpty
            ? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("CascViewer").path ?? "")
            : AppSettings.shared.cdnCachePath
        let cachePath = (baseCachePath as NSString).appendingPathComponent(product)

        let fm = FileManager.default
        let versionsFile = (cachePath as NSString).appendingPathComponent("versions")
        let cdnsFile = (cachePath as NSString).appendingPathComponent("cdns")
        let cacheExists = fm.fileExists(atPath: versionsFile) || fm.fileExists(atPath: cdnsFile)

        guard cacheExists else { return true }

        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = L("cache_exists_title")
            alert.informativeText = L("cache_exists_message")
            alert.addButton(withTitle: L("use_history_cache"))
            alert.addButton(withTitle: L("overwrite_redownload"))
            alert.addButton(withTitle: L("cancel"))
            alert.alertStyle = .informational

            guard let window = shared?.window else {
                // Fallback to synchronous if window is missing
                let response = alert.runModal()
                continuation.resume(returning: handleCacheAlertResponse(response, cachePath: cachePath))
                return
            }

            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: handleCacheAlertResponse(response, cachePath: cachePath))
            }
        }
    }

    private static func handleCacheAlertResponse(_ response: NSApplication.ModalResponse, cachePath: String) -> Bool {
        let fm = FileManager.default
        switch response {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            do {
                if fm.fileExists(atPath: cachePath) {
                    try fm.removeItem(atPath: cachePath)
                }
                try fm.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
            } catch {
                return false
            }
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        OnlineStorageWindowController.lock.lock()
        Self.shared = nil
        OnlineStorageWindowController.lock.unlock()
    }
}
