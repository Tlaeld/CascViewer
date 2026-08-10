import XCTest
import CascBridge
@testable import CascViewer

final class WhiteoutBridgeTests: XCTestCase {

    private func decode(_ bytes: Data) -> WhiteoutBridge.WOImageDecodeResult {
        var data = bytes
        var error = WhiteoutBridge.WOError.None
        var decoder = WhiteoutBridge.WOTextureDecoder()
        return data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }
    }

    func testBLP2RoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestImage(16, 16, 1)
        XCTAssertGreaterThan(bytes.size(), 0)
        let result = decode(Data(bytes))
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.BLP2)
        XCTAssertEqual(result.width, 16)
        XCTAssertEqual(result.height, 16)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 16 * 16 * 4)
        XCTAssertGreaterThanOrEqual(result.mipLevels, 1)
    }

    func testBLP1RoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestImage(16, 16, 0)
        XCTAssertGreaterThan(bytes.size(), 0)
        let result = decode(Data(bytes))
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.BLP1)
        XCTAssertEqual(result.width, 16)
    }

    func testDDSRoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestImage(16, 16, 2)
        XCTAssertGreaterThan(bytes.size(), 0)
        let result = decode(Data(bytes))
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.DDS)
        XCTAssertEqual(result.width, 16)
    }

    func testDDS24BitDecodeInMemory() {
        // Build a minimal 4x4 DDS uncompressed 24-bit BGR file in memory
        var bytes = [UInt8]()

        func appendU32(_ value: UInt32) {
            bytes.append(contentsOf: [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF)
            ])
        }

        // Magic: "DDS "
        bytes.append(contentsOf: [0x44, 0x44, 0x53, 0x20])
        appendU32(124)
        appendU32(0x0008100F) // caps | height | width | pixelformat | pitch
        appendU32(4)          // height
        appendU32(4)          // width
        appendU32(12)         // pitch = 4 * 3 (compact, no row padding)
        appendU32(0)          // depth
        appendU32(0)          // mipmaps
        for _ in 0..<11 { appendU32(0) }
        // Pixel format
        appendU32(32)         // pfSize
        appendU32(0x40)       // pfFlags: DDPF_RGB only
        appendU32(0)          // pfFourCC
        appendU32(24)         // pfRGBBitCount
        appendU32(0x00FF0000) // pfRBitMask
        appendU32(0x0000FF00) // pfGBitMask
        appendU32(0x000000FF) // pfBBitMask
        appendU32(0x00000000) // pfABitMask
        appendU32(0x1000)     // dwCaps
        appendU32(0)
        appendU32(0)
        appendU32(0)
        appendU32(0)

        XCTAssertEqual(bytes.count, 128)

        // Pixel data: 4x4 BGR compact (no row padding), first pixel Blue
        bytes.append(contentsOf: [0xFF, 0x00, 0x00])
        for _ in 1..<16 { bytes.append(contentsOf: [0x00, 0x00, 0x00]) }

        let result = decode(Data(bytes))
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.DDS)
        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 4 * 4 * 4)
        // Pixel (0,0): Blue in BGR -> RGBA(00, 00, FF, FF)
        XCTAssertEqual(result.frames[0].rgbaData[0], 0x00)
        XCTAssertEqual(result.frames[0].rgbaData[1], 0x00)
        XCTAssertEqual(result.frames[0].rgbaData[2], 0xFF)
        XCTAssertEqual(result.frames[0].rgbaData[3], 0xFF)
    }

    func testGarbageFails() {
        let garbage: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4]
        var error = WhiteoutBridge.WOError.None
        var decoder = WhiteoutBridge.WOTextureDecoder()
        garbage.withUnsafeBufferPointer { buf in
            _ = decoder.decode(buf.baseAddress!, buf.count, &error)
        }
        XCTAssertNotEqual(error, WhiteoutBridge.WOError.None)
    }
}
