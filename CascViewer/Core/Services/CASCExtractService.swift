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

        let total = entries.count
        for (index, entry) in entries.enumerated() {
            currentFile = entry.name
            let destPath: String
            if preserveStructure {
                destPath = destination.appendingPathComponent(entry.fullPath).path
            } else {
                destPath = destination.appendingPathComponent(entry.name).path
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    let result = self.storage.extractFile(std.string(entry.fullPath), std.string(destPath))
                    if result != .None {
                        continuation.resume(throwing: self.mapError(result))
                    } else {
                        continuation.resume()
                    }
                }
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
