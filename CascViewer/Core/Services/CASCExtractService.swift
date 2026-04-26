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

    func extract(entries: [CASCFileEntry], to destination: URL, preserveStructure: Bool) async throws {
        isExtracting = true
        progress = 0
        defer { isExtracting = false }

        var handle = storage
        let total = entries.count
        for (index, entry) in entries.enumerated() {
            currentFile = entry.name
            let sanitizedPath = entry.fullPath
                .components(separatedBy: "/")
                .filter { $0 != ".." && !$0.isEmpty }
                .joined(separator: "/")

            let destPath: String
            if preserveStructure {
                destPath = destination.appendingPathComponent(sanitizedPath).path
            } else {
                destPath = destination.appendingPathComponent(entry.name).path
            }

            let result: CascBridge.CascError = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
                queue.async {
                    let result = handle.extractFile(std.string(sanitizedPath), std.string(destPath))
                    continuation.resume(returning: result)
                }
            }

            if result != .None {
                throw mapError(result)
            }

            progress = Double(index + 1) / Double(total)
        }
    }

    private func mapError(_ error: CascBridge.CascError) -> CASCError {
        switch error {
        case .FileNotFound: return .fileNotFound
        case .ReadError: return .readError
        default: return .unknown
        }
    }
}
