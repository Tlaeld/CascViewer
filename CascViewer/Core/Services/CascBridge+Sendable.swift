import Foundation
import CascBridge

extension CascBridge.CascStorageHandle: @unchecked Sendable { }

extension CascBridge.CascError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .None:
            return "Success"
        case .InvalidPath:
            return L("error_invalid_path")
        case .StorageNotFound:
            return L("error_storage_not_found")
        case .StorageCorrupted:
            return L("error_storage_corrupted")
        case .FileNotFound:
            return L("error_file_not_found")
        case .ReadError:
            return L("error_read_error")
        case .NetworkError:
            return L("error_network")
        case .CDNConfigError:
            return L("error_cdn_config")
        case .DecodingError:
            return L("error_decoding")
        case .NotImplemented:
            return L("error_not_implemented")
        case .Cancelled:
            return L("error_cancelled")
        case .Unknown:
            return L("error_unknown")
        @unknown default:
            return L("error_unknown")
        }
    }
}
