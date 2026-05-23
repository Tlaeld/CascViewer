import Foundation
import CoreImage
import CascBridge

actor BLPDecoderCoordinator {
    private var decoder = CascBridge.ImageDecoderBridge()

    func decode(data: Data) async throws -> ImageDecodeResult {
        guard !data.isEmpty else { throw CASCError.decodingError }
        var error = CascBridge.CascError.None
        let result = data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return CascBridge.ImageDecodeResult()
            }
            return decoder.decode(ptr, data.count, &error)
        }
        if error != .None {
            throw CASCError.decodingError
        }
        return ImageDecodeResult(cppResult: result)
    }
}

struct ImageDecodeResult {
    let format: BLPImageInfo.ImageFormat
    let width: UInt32
    let height: UInt32
    let mipLevels: UInt32
    let frameCount: UInt32
    let hasAlpha: Bool
    let frames: [ImageFrame]
    let mipMaps: [[ImageFrame]]

    struct ImageFrame {
        let width: UInt32
        let height: UInt32
        let imageData: Data  // RGBA8888

        private static let sharedColorSpace = CGColorSpaceCreateDeviceRGB()

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
                space: ImageFrame.sharedColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    init(cppResult: CascBridge.ImageDecodeResult) {
        switch cppResult.format {
        case .BLP2: format = .blp2
        case .DDS: format = .dds
        default: format = .blp1
        }
        width = cppResult.width
        height = cppResult.height
        mipLevels = cppResult.mipLevels
        frameCount = cppResult.frameCount
        hasAlpha = cppResult.hasAlpha

        frames = (0..<cppResult.frames.size()).map { i in
            let frame = cppResult.frames[i]
            return ImageFrame(
                width: frame.width,
                height: frame.height,
                imageData: Data(frame.rgbaData)
            )
        }

        mipMaps = (0..<cppResult.mipMaps.size()).map { i in
            let level = cppResult.mipMaps[i]
            return (0..<level.size()).map { j in
                let frame = level[j]
                return ImageFrame(
                    width: frame.width,
                    height: frame.height,
                    imageData: Data(frame.rgbaData)
                )
            }
        }
    }
}
