import Foundation

struct BLPImageInfo {
    let format: BLPFormat
    let width: UInt32
    let height: UInt32
    let mipLevels: UInt32
    let frameCount: UInt32
    let hasAlpha: Bool

    enum BLPFormat {
        case blp1
        case blp2
    }
}
