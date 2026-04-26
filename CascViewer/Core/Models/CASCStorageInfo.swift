import Foundation

struct CASCStorageInfo: Sendable {
    let productName: String
    let buildVersion: String
    let totalFiles: UInt64
    let totalSize: UInt64
}
