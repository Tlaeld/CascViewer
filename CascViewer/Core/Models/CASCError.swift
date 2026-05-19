import Foundation

enum CASCError: Error, LocalizedError, Sendable {
    case invalidPath
    case storageNotFound
    case storageCorrupted
    case fileNotFound
    case fileNotAvailable
    case readError
    case networkError
    case cdnConfigError
    case decodingError
    case cancelled
    case unknown
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "Invalid path or configuration."
        case .storageNotFound: return "Storage not found at the specified path."
        case .storageCorrupted: return "Storage appears to be corrupted."
        case .fileNotFound: return "File not found in storage."
        case .fileNotAvailable: return "File data is not available locally or on CDN."
        case .readError: return "Failed to read file data."
        case .networkError: return "Network error. Please check your connection."
        case .cdnConfigError: return "Failed to fetch CDN configuration."
        case .decodingError: return "Failed to decode file data."
        case .cancelled: return "Operation was cancelled by user."
        case .unknown: return "An unknown error occurred."
        case .notImplemented: return "This feature is not yet implemented."
        }
    }
}
