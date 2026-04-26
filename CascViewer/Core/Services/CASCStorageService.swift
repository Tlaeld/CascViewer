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

    var handle: CascBridge.CascStorageHandle
    private let queue = DispatchQueue(label: "casc.storage", qos: .userInitiated)

    init(storage: CascBridge.CascStorageHandle) {
        self.handle = storage
    }

    deinit {
        handle.close()
    }

    func openLocal(path: String) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        var localHandle = handle
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
            queue.async {
                let result = localHandle.open(std.string(path))
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
        guard !isLoading else { return }
        isLoading = true
        error = nil
        let config = "\(product):\(region)"
        var localHandle = handle
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
            queue.async {
                let result = localHandle.open(std.string(config))
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
        guard !isLoading else { return }
        isLoading = true
        var localHandle = handle
        let (newEntries, err) = await withCheckedContinuation { (continuation: CheckedContinuation<([CASCFileEntry], CascBridge.CascError), Never>) in
            queue.async {
                var error = CascBridge.CascError.None
                let rawEntries = localHandle.listDirectory(std.string(path), &error)
                let mapped = (0..<rawEntries.size()).map { i in
                    let entry = rawEntries[i]
                    return CASCFileEntry(
                        name: String(entry.name),
                        fullPath: String(entry.fullPath),
                        type: entry.type == .File ? .file : .directory,
                        size: entry.size,
                        encodingKey: String(entry.encodingKey)
                    )
                }
                continuation.resume(returning: (mapped, error))
            }
        }
        isLoading = false
        if err != .None {
            self.error = mapError(err)
        } else {
            self.entries = newEntries
            self.currentPath = path
        }
    }

    func close() {
        handle.close()
        entries = []
        currentPath = ""
        storageInfo = nil
    }

    private func refreshStorageInfo() async {
        var localHandle = handle
        let (info, err) = await withCheckedContinuation { (continuation: CheckedContinuation<(CascBridge.CascStorageInfo, CascBridge.CascError), Never>) in
            queue.async {
                var error = CascBridge.CascError.None
                let info = localHandle.getStorageInfo(&error)
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
