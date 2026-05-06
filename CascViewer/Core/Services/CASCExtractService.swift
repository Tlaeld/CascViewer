import Foundation
import Combine
import CascBridge

@MainActor
final class CASCExtractService: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExtracting = false
    @Published var currentFile: String = ""

    private var storage: CascBridge.CascStorageHandle
    private let queue = DispatchQueue(label: "casc.extract", qos: .userInitiated)

    init(storage: CascBridge.CascStorageHandle) {
        self.storage = storage
    }

    struct ExtractResult {
        let successCount: Int
        let failedFiles: [(path: String, error: CASCError)]
    }

    func extract(entries: [CASCFileEntry], to destination: URL, preserveStructure: Bool) async -> ExtractResult {
        isExtracting = true
        progress = 0
        defer { isExtracting = false }

        var handle = storage
        let total = entries.count
        var successCount = 0
        var failedFiles = [(path: String, error: CASCError)]()
        var createdDirs = Set<String>()

        for (index, entry) in entries.enumerated() {
            if index % 10 == 0 || index == total - 1 {
                currentFile = entry.name
            }

            let sanitizedPath = entry.normalizedPath
                .components(separatedBy: "/")
                .filter { $0 != ".." && !$0.isEmpty }
                .joined(separator: "/")

            let destPath: String
            if preserveStructure {
                destPath = destination.appendingPathComponent(sanitizedPath).path
            } else {
                destPath = destination.appendingPathComponent(entry.name).path
            }
            
            // Ensure parent directories exist before extraction
            let destURL = URL(fileURLWithPath: destPath)
            let parentDir = destURL.deletingLastPathComponent().path
            if createdDirs.insert(parentDir).inserted {
                try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }

            let result: CascBridge.CascError = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
                queue.async {
                    let result = handle.extractFile(std.string(sanitizedPath), std.string(destPath))
                    continuation.resume(returning: result)
                }
            }

            if result == .None {
                successCount += 1
            } else {
                failedFiles.append((path: entry.fullPath, error: mapError(result)))
            }

            let newProgress = Double(index + 1) / Double(total)
            if newProgress - progress > 0.01 || index == total - 1 {
                progress = newProgress
            }
        }

        return ExtractResult(successCount: successCount, failedFiles: failedFiles)
    }

    private func mapError(_ error: CascBridge.CascError) -> CASCError {
        switch error {
        case .FileNotFound: return .fileNotFound
        case .ReadError: return .readError
        default: return .unknown
        }
    }
}
