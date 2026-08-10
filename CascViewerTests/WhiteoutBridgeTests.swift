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
