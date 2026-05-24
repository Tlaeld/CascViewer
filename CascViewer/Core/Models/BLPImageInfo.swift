import Foundation

struct BLPImageInfo: Sendable {
    let format: ImageFormat
    let width: UInt32
    let height: UInt32
    let mipLevels: UInt32
    let frameCount: UInt32
    let hasAlpha: Bool

    enum ImageFormat: Sendable {
        case blp1
        case blp2
        case dds
        case other
    }
}
