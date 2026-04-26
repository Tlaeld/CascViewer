import Foundation

struct BLPImageInfo: Sendable {
    let format: BLPFormat
    let width: UInt32
    let height: UInt32
    let mipLevels: UInt32
    let frameCount: UInt32
    let hasAlpha: Bool

    enum BLPFormat: Sendable {
        case blp1
        case blp2
    }
}
