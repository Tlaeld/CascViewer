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

    deinit {
        storage.close()
    }

    func openLocal(path: String) async {
        isLoading = true
        error = nil
        var handle = storage
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
            queue.async {
                let result = handle.open(std.string(path))
                continuation.resume(returning: result)
            }
        }
        isLoading = false
        if result != .None {
            self.error = mapError(result)
        } else {
            await refreshStorageInfo()
            await listDirectory(path: "")
        }
    }

    func openOnline(product: String, region: String) async {
        isLoading = true
        error = nil
        let config = "\(product):\(region)"
        var handle = storage
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
            queue.async {
                let result = handle.open(std.string(config))
                continuation.resume(returning: result)
            }
        }
        isLoading = false
        if result != .None {
            self.error = mapError(result)
        } else {
            await refreshStorageInfo()
            await listDirectory(path: "")
        }
    }

    func listDirectory(path: String) async {
        isLoading = true
        var handle = storage
        let (items, err) = await withCheckedContinuation { (continuation: CheckedContinuation<([CascBridge.CascFileEntry], CascBridge.CascError), Never>) in
            queue.async {
                var error = CascBridge.CascError.None
                let rawEntries = handle.listDirectory(std.string(path), &error)
                let entries = (0..<rawEntries.size()).map { rawEntries[$0] }
                continuation.resume(returning: (entries, error))
            }
        }
        isLoading = false
        if err != .None {
            self.error = mapError(err)
        } else {
            self.entries = items.map { entry in
                CASCFileEntry(
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

    func close() {
        storage.close()
        entries = []
        currentPath = ""
        storageInfo = nil
    }

    private func refreshStorageInfo() async {
        var handle = storage
        let (info, err) = await withCheckedContinuation { (continuation: CheckedContinuation<(CascBridge.CascStorageInfo, CascBridge.CascError), Never>) in
            queue.async {
                var error = CascBridge.CascError.None
                let info = handle.getStorageInfo(&error)
                continuation.resume(returning: (info, error))
            }
        }
        if err == .None {
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
