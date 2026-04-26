import Foundation
import Combine
import CascBridge

@MainActor
final class CASCStorageService: ObservableObject {
    @Published var currentPath: String = ""
    @Published var entries: [CASCFileEntry] = []
    @Published var storageInfo: CASCStorageInfo?
    @Published var isLoading = false
    @Published var error: CASCError?

    private var storage: CascBridge.CascStorageHandle
    private let queue = DispatchQueue(label: "casc.storage", qos: .userInitiated)

    init(storage: CascBridge.CascStorageHandle) {
        self.storage = storage
    }

    func openLocal(path: String) async {
        isLoading = true
        error = nil

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let result = self.storage.open(std.string(path))
                Task { @MainActor in
                    self.isLoading = false
                    if result != .None {
                        self.error = self.mapError(result)
                    } else {
                        self.refreshStorageInfo()
                        self.listDirectory(path: "")
                    }
                    continuation.resume()
                }
            }
        }
    }

    func openOnline(product: String, region: String) async {
        isLoading = true
        error = nil
        let config = "\(product):\(region)"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let result = self.storage.open(std.string(config))
                Task { @MainActor in
                    self.isLoading = false
                    if result != .None {
                        self.error = self.mapError(result)
                    } else {
                        self.refreshStorageInfo()
                        self.listDirectory(path: "")
                    }
                    continuation.resume()
                }
            }
        }
    }

    func listDirectory(path: String) {
        isLoading = true
        queue.async {
            var error = CascBridge.CascError.None
            let items = self.storage.listDirectory(std.string(path), &error)
            DispatchQueue.main.async {
                self.isLoading = false
                if error != .None {
                    self.error = self.mapError(error)
                } else {
                    self.entries = (0..<items.size()).map { i in
                        let entry = items[i]
                        return CASCFileEntry(
                            name: String(entry.name),
                            fullPath: String(entry.fullPath),
                            type: entry.type == .File ? .file : .directory,
                            size: entry.size,
                            encodingKey: String(entry.encodingKey)
                        )
                    }
                    self.currentPath = path
                }
            }
        }
    }

    func close() {
        storage.close()
        entries = []
        currentPath = ""
        storageInfo = nil
    }

    private func refreshStorageInfo() {
        var error = CascBridge.CascError.None
        let info = storage.getStorageInfo(&error)
        if error == .None {
            self.storageInfo = CASCStorageInfo(
                productName: String(info.productName),
                buildVersion: String(info.buildVersion),
                totalFiles: info.totalFiles,
                totalSize: 0
            )
        }
    }

    private func mapError(_ error: CascBridge.CascError) -> CASCError {
        switch error {
        case .InvalidPath: return .invalidPath
        case .StorageNotFound: return .storageNotFound
        case .StorageCorrupted: return .storageCorrupted
        case .FileNotFound: return .fileNotFound
        case .ReadError: return .readError
        case .NetworkError: return .networkError
        case .CDNConfigError: return .cdnConfigError
        case .DecodingError: return .decodingError
        default: return .unknown
        }
    }
}
