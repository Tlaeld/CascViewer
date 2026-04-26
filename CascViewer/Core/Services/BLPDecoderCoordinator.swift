import Foundation
import CoreImage
import CascBridge

actor BLPDecoderCoordinator {
    private var decoder = CascBridge.BLPDecoderBridge()

    func decode(data: Data) async throws -> BLPDecodeResult {
        var error = CascBridge.CascError.None
        let result = data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }
        if error != .None {
            throw CASCError.decodingError
        }
        return BLPDecodeResult(cppResult: result)
    }
}

struct BLPDecodeResult {
    let format: BLPImageInfo.BLPFormat
    let width: UInt32
    let height: UInt32
    let mipLevels: UInt32
    let frameCount: UInt32
    let hasAlpha: Bool
    let frames: [BLPFrame]
    let mipMaps: [[BLPFrame]]

    struct BLPFrame {
        let width: UInt32
        let height: UInt32
        let imageData: Data  // RGBA8888

        var cgImage: CGImage? {
            let bytesPerPixel = 4
            let bytesPerRow = Int(width) * bytesPerPixel
            guard let provider = CGDataProvider(data: imageData as CFData) else { return nil }
            return CGImage(
                width: Int(width),
                height: Int(height),
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    init(cppResult: CascBridge.BLPDecodeResult) {
        format = cppResult.format == .BLP2 ? .blp2 : .blp1
        width = cppResult.width
        height = cppResult.height
        mipLevels = cppResult.mipLevels
        frameCount = cppResult.frameCount
        hasAlpha = cppResult.hasAlpha

        frames = (0..<cppResult.frames.size()).map { i in
            let frame = cppResult.frames[i]
            return BLPFrame(
                width: frame.width,
                height: frame.height,
                imageData: Data(frame.rgbaData.map { $0 })
            )
        }

        mipMaps = (0..<cppResult.mipMaps.size()).map { i in
            let level = cppResult.mipMaps[i]
            return (0..<level.size()).map { j in
                let frame = level[j]
                return BLPFrame(
                    width: frame.width,
                    height: frame.height,
                    imageData: Data(frame.rgbaData.map { $0 })
                )
            }
        }
    }
}
