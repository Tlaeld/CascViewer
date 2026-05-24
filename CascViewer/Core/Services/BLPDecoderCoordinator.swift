import Foundation
import CoreImage
import CascBridge

actor BLPDecoderCoordinator {
    private var decoder = CascBridge.ImageDecoderBridge()

    func decode(data: Data) async throws -> ImageDecodeResult {
        guard !data.isEmpty else { throw CASCError.decodingError }

        // Try native C++ decoder first (BLP, DDS)
        var error = CascBridge.CascError.None
        let cppResult: CascBridge.ImageDecodeResult? = data.withUnsafeBytes { rawBuffer -> CascBridge.ImageDecodeResult? in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return decoder.decode(ptr, data.count, &error)
        }
        if let cppResult = cppResult, error == .None {
            return ImageDecodeResult(cppResult: cppResult)
        }

        // Fallback to system ImageIO for PNG, JPEG, GIF, BMP, TGA, etc.
        if let ioResult = decodeViaImageIO(data: data) {
            return ioResult
        }

        throw CASCError.decodingError
    }

    private func decodeViaImageIO(data: Data) -> ImageDecodeResult? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else { return nil }

        let bytesPerPixel = 4
        let width64 = Int64(width)
        let height64 = Int64(height)
        let bytesPerRow64 = width64 * Int64(bytesPerPixel)
        let totalBytes64 = height64 * bytesPerRow64
        guard totalBytes64 <= Int64(Int.max) else { return nil }

        var rgbaData = Data(count: Int(totalBytes64))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let success = rgbaData.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            guard let context = CGContext(
                data: ptr,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: Int(bytesPerRow64),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }

        let frame = ImageDecodeResult.ImageFrame(
            width: UInt32(width),
            height: UInt32(height),
            imageData: rgbaData
        )
        return ImageDecodeResult(
            format: .other,
            width: UInt32(width),
            height: UInt32(height),
            mipLevels: 1,
            frameCount: 1,
            hasAlpha: cgImage.alphaInfo != .none,
            frames: [frame],
            mipMaps: [[frame]]
        )
    }
}

struct ImageDecodeResult: Sendable {
    let format: BLPImageInfo.ImageFormat
    let width: UInt32
    let height: UInt32
    let mipLevels: UInt32
    let frameCount: UInt32
    let hasAlpha: Bool
    let frames: [ImageFrame]
    let mipMaps: [[ImageFrame]]

    struct ImageFrame: Sendable {
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

    init(format: BLPImageInfo.ImageFormat,
         width: UInt32,
         height: UInt32,
         mipLevels: UInt32,
         frameCount: UInt32,
         hasAlpha: Bool,
         frames: [ImageFrame],
         mipMaps: [[ImageFrame]]) {
        self.format = format
        self.width = width
        self.height = height
        self.mipLevels = mipLevels
        self.frameCount = frameCount
        self.hasAlpha = hasAlpha
        self.frames = frames
        self.mipMaps = mipMaps
    }
}
