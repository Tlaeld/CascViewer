import Foundation
import CascBridge

// MARK: - File Reader Protocol

/// Abstracts file read operations from the underlying C++ CascLib handle.
/// Enables testing search and preview logic without linking against the
/// real C++ bridge.
protocol CASCFileReader: Sendable {
    /// Read a portion of a file from the storage.
    /// - Returns: The data if successful, nil on error or if the file is not available.
    func readFilePartial(path: String, offset: UInt64, length: UInt64) -> Data?
}

// MARK: - File Extractor Protocol

/// Abstracts file extraction operations from the underlying C++ CascLib handle.
protocol CASCFileExtractor: Sendable {
    /// Extract a single file from CASC storage to the local filesystem.
    /// - Parameters:
    ///   - cascPath: Source path inside the CASC storage.
    ///   - destPath: Destination path on the local filesystem.
    ///   - progress: Optional closure called with (currentBytes, totalBytes).
    /// - Returns: `.None` on success, or an error code.
    func extractFile(cascPath: String, destPath: String, progress: ((Int64, Int64) -> Void)?) -> CascBridge.CascError

    /// Signal the extractor to cancel the current extraction at the next opportunity.
    func requestCancelExtraction()
}

// MARK: - Combined Protocol

protocol CASCStorageHandleProtocol: CASCFileReader, CASCFileExtractor {}

// MARK: - Adapter for CascStorageHandle

/// Bridges `CascBridge.CascStorageHandle` to the Swift-friendly protocols.
/// All C++ interop (std.string, C callbacks, etc.) lives here.
final class CascStorageHandleAdapter: CASCStorageHandleProtocol, @unchecked Sendable {
    var handle: CascBridge.CascStorageHandle

    init(handle: CascBridge.CascStorageHandle) {
        self.handle = handle
    }

    func readFilePartial(path: String, offset: UInt64, length: UInt64) -> Data? {
        var error = CascBridge.CascError.None
        let buffer = handle.readFilePartial(std.string(path), offset, length, &error)
        guard error == .None else { return nil }
        return Data(buffer)
    }

    func extractFile(cascPath: String, destPath: String, progress: ((Int64, Int64) -> Void)?) -> CascBridge.CascError {
        guard let progress = progress else {
            return handle.extractFile(std.string(cascPath), std.string(destPath))
        }

        let box = ProgressBox(progress: progress)
        let rawContext = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(rawContext).release() }

        let progressBlock: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64) -> Void = { context, current, total in
            guard let ctx = context else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            box.progress(current, total)
        }

        return handle.extractFile(std.string(cascPath), std.string(destPath), progressBlock, rawContext)
    }

    func requestCancelExtraction() {
        handle.requestCancelExtraction()
    }
}

/// Internal box to pass a Swift closure through a C-style callback context pointer.
private final class ProgressBox {
    let progress: (Int64, Int64) -> Void
    init(progress: @escaping (Int64, Int64) -> Void) {
        self.progress = progress
    }
}

// MARK: - Mock Implementations (for tests)

#if DEBUG
final class MockFileReader: CASCFileReader, @unchecked Sendable {
    var files: [String: Data] = [:]
    var shouldFailPaths: Set<String> = []

    func readFilePartial(path: String, offset: UInt64, length: UInt64) -> Data? {
        guard !shouldFailPaths.contains(path),
              let data = files[path] else {
            return nil
        }
        let start = min(Int(offset), data.count)
        let end = min(start + Int(length), data.count)
        guard start < end else { return Data() }
        return data.subdata(in: start..<end)
    }
}

final class MockFileExtractor: CASCFileExtractor, @unchecked Sendable {
    var shouldSucceed = true
    var wasCancelRequested = false
    var extractedFiles: [(cascPath: String, destPath: String)] = []
    var progressCalls: [(Int64, Int64)] = []

    func extractFile(cascPath: String, destPath: String, progress: ((Int64, Int64) -> Void)?) -> CascBridge.CascError {
        extractedFiles.append((cascPath: cascPath, destPath: destPath))
        if shouldSucceed {
            progress?(100, 100)
            progressCalls.append((100, 100))
            return .None
        } else {
            return .FileNotFound
        }
    }

    func requestCancelExtraction() {
        wasCancelRequested = true
    }
}
#endif
