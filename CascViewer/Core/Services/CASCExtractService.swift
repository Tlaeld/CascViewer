import Foundation
import Combine
import CascBridge

@MainActor
final class CASCExtractService: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExtracting = false
    @Published var currentFile: String = ""

    private let extractor: CASCFileExtractor
    private let queue = DispatchQueue(label: "casc.extract", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var _isCancelled = false

    init(extractor: CASCFileExtractor) {
        self.extractor = extractor
    }

    /// Convenience init for callers that still have a raw CascStorageHandle.
    convenience init(storage: CascBridge.CascStorageHandle) {
        self.init(extractor: CascStorageHandleAdapter(handle: storage))
    }

    struct ExtractResult {
        let successCount: Int
        let failedFiles: [(path: String, error: CASCError)]
        let wasCancelled: Bool
    }

    private class ExtractProgressContext {
        weak var service: CASCExtractService?
        let fileIndex: Int
        let totalFiles: Int

        init(service: CASCExtractService, fileIndex: Int, totalFiles: Int) {
            self.service = service
            self.fileIndex = fileIndex
            self.totalFiles = totalFiles
        }
    }

    var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return _isCancelled
    }

    private func setCancelled(_ value: Bool) {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        _isCancelled = value
    }

    func cancel() {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        _isCancelled = true
        extractor.requestCancelExtraction()
    }

    func extract(entries: [CASCFileEntry], to destination: URL, preserveStructure: Bool, overwriteExisting: Bool = false) async -> ExtractResult {
        guard !isExtracting else { return ExtractResult(successCount: 0, failedFiles: [], wasCancelled: false) }
        isExtracting = true
        progress = 0
        setCancelled(false)
        defer { isExtracting = false }

        let extractor = self.extractor
        let total = entries.count
        var successCount = 0
        var failedFiles = [(path: String, error: CASCError)]()
        var createdDirs = Set<String>()

        for (index, entry) in entries.enumerated() {
            if isCancelled {
                break
            }

            if index % 10 == 0 || index == total - 1 {
                currentFile = entry.name
            }

            // Offload per-file I/O to a detached task so the MainActor is preserved
            // after the await (Swift 6 compatibility).
            let fileIndex = index
            let result: CascBridge.CascError = await Task.detached(priority: .userInitiated) { [extractor, destination, preserveStructure, overwriteExisting] in
                let sanitizedPath = entry.normalizedPath
                    .components(separatedBy: "/")
                    .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
                    .joined(separator: "/")

                let sanitizedName = entry.name
                    .components(separatedBy: "/")
                    .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
                    .joined(separator: "_")

                if sanitizedPath.isEmpty || sanitizedName.isEmpty {
                    return .InvalidPath
                }

                let destPath: String
                if preserveStructure {
                    destPath = destination.appendingPathComponent(sanitizedPath).path
                } else {
                    destPath = destination.appendingPathComponent(sanitizedName).path
                }

                if !overwriteExisting && FileManager.default.fileExists(atPath: destPath) {
                    return .None
                }

                let destURL = URL(fileURLWithPath: destPath)
                let parentDir = destURL.deletingLastPathComponent().path
                do {
                    try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                } catch {
                    return .InvalidPath
                }

                let result = extractor.extractFile(
                    cascPath: sanitizedPath,
                    destPath: destPath,
                    progress: { current, totalBytes in
                        let fileProgress = totalBytes > 0 ? Double(current) / Double(totalBytes) : 0
                        let overallProgress = (Double(fileIndex) + fileProgress) / Double(total)
                        Task { @MainActor [weak self] in
                            self?.progress = overallProgress
                        }
                    }
                )
                return result
            }.value

            if isCancelled {
                break
            }

            if result == .None {
                successCount += 1
            } else if result == .Cancelled {
                break
            } else {
                var cascError = mapError(result)
                if cascError == .fileNotFound && !entry.isLocal {
                    cascError = .fileNotAvailable
                }
                failedFiles.append((path: entry.fullPath, error: cascError))
            }

            let newProgress = Double(index + 1) / Double(total)
            if newProgress - progress > 0.01 || index == total - 1 {
                progress = newProgress
            }
        }

        return ExtractResult(successCount: successCount, failedFiles: failedFiles, wasCancelled: isCancelled)
    }

    private func mapError(_ error: CascBridge.CascError) -> CASCError {
        switch error {
        case .FileNotFound: return .fileNotFound
        case .ReadError: return .readError
        case .Cancelled: return .cancelled
        case .InvalidPath: return .invalidPath
        case .StorageNotFound: return .storageNotFound
        case .StorageCorrupted: return .storageCorrupted
        case .NetworkError: return .networkError
        case .CDNConfigError: return .cdnConfigError
        case .DecodingError: return .decodingError
        case .NotImplemented: return .notImplemented
        case .None: return .unknown
        @unknown default: return .unknown
        }
    }
}
