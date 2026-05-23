import Foundation
import CascBridge

/// `CascStorageHandle` is `@unchecked Sendable` because all internal state
/// is protected by a `std::mutex` on the C++ side. Every public method on the
/// C++ handle acquires an exclusive lock before touching the underlying
/// `LocalCascStorage` or CascLib handle. Swift callers may pass the handle
/// across concurrency boundaries (e.g. into `TaskGroup` or `@Sendable`
/// closures) as long as they do not bypass the handle and mutate the C++
/// object directly.
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
