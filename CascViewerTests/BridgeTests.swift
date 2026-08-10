import XCTest
import CascBridge
@testable import CascViewer

final class BridgeTests: XCTestCase {
    func testCascStorageHandleOpenInvalidPath() {
        var storage = CascBridge.CascStorageHandle.createLocal()
        let error = storage.open(std.string("/nonexistent/path"))
        XCTAssertNotEqual(error, CascBridge.CascError.None)
    }

    func testCASCErrorAllCasesHaveDescriptions() {
        let errors: [CASCError] = [.invalidPath, .storageNotFound, .storageCorrupted, .fileNotFound, .fileNotAvailable, .readError, .networkError, .cdnConfigError, .decodingError, .unknown, .notImplemented, .cancelled]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    @MainActor
    func testCASCSearchServiceWildcard() async {
        let mockReader = MockFileReader()
        mockReader.files = [
            "a/tex1.blp": Data(),
            "a/tex2.blp": Data(),
            "a/model.mdx": Data()
        ]
        let searchService = CASCSearchService(reader: mockReader)

        let testEntries = [
            CASCFileEntry(name: "tex1.blp", fullPath: "a/tex1.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "tex2.blp", fullPath: "a/tex2.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "model.mdx", fullPath: "a/model.mdx", type: .file, size: 100, encodingKey: "")
        ]

        let request = SearchRequest(mode: .filename, query: "*.blp", scope: .entireStorage, caseSensitive: false, useRegex: false, includePath: false, fileTypes: [], selectedTags: [], availableTags: [])
        let results = await searchService.search(request, allEntries: testEntries, entries: testEntries, currentPath: "")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.entry.name.hasSuffix(".blp") })
    }

    func testBLP2RawDecodeInMemory() {
        let bytes = WhiteoutBridge.WOEncodeTestImage(4, 4, 1)
        XCTAssertGreaterThan(bytes.size(), 0)
        var data = Data(bytes)
        var error = WhiteoutBridge.WOError.None
        var decoder = WhiteoutBridge.WOTextureDecoder()
        let result = data.withUnsafeBytes { rawBuffer -> WhiteoutBridge.WOImageDecodeResult in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }
        XCTAssertEqual(error, WhiteoutBridge.WOError.None)
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.BLP2)
        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 4 * 4 * 4)
    }

    func testDDSUncompressedBGRADecodeRealFile() throws {
        let path = "/Users/dev/Desktop/mods/heroes.stormmod/eses.stormassets/assets/textures/storm_ui_hud_volskaya_overtime_text.dds"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real DDS file not found at \(path)")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            XCTFail("Failed to read DDS file")
            return
        }

        var decoder = WhiteoutBridge.WOTextureDecoder()
        var error = WhiteoutBridge.WOError.None
        let result = data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }

        XCTAssertEqual(error, WhiteoutBridge.WOError.None, "Real DDS decoding failed")
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.DDS)
        XCTAssertEqual(result.width, 208)
        XCTAssertEqual(result.height, 72)
        XCTAssertEqual(result.compression, WhiteoutBridge.WOImageCompression.Raw)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 208 * 72 * 4)
    }

    func testImageIOFallbackPNG() async throws {
        // 2x2 solid red PNG (RGBA)
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFUlEQVR4nGP8z8Dwn4GBgYEJRIAwAB8XAgICR7MUAAAAAElFTkSuQmCC"
        guard let data = Data(base64Encoded: base64) else {
            XCTFail("Failed to decode base64 PNG")
            return
        }

        let coordinator = BLPDecoderCoordinator()
        let result = try await coordinator.decode(data: data)

        XCTAssertEqual(result.format, .other)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames[0].imageData.count, 2 * 2 * 4)

        // Verify first pixel is red (solid red premultiplies to same value)
        let rgba = result.frames[0].imageData
        XCTAssertEqual(rgba[0], 0xFF)
        XCTAssertEqual(rgba[1], 0x00)
        XCTAssertEqual(rgba[2], 0x00)
        XCTAssertEqual(rgba[3], 0xFF)
    }

    func testDDSRawDecodeInMemory() {
        // WhiteoutLib 的 DDS parser 只接受每像素 4 字节的格式(24-bit BGR 不再支持),
        // 改用 writer round-trip 夹具生成 DDS 字节。
        let bytes = WhiteoutBridge.WOEncodeTestImage(2, 2, 2)
        XCTAssertGreaterThan(bytes.size(), 0)
        var data = Data(bytes)
        var error = WhiteoutBridge.WOError.None
        var decoder = WhiteoutBridge.WOTextureDecoder()
        let result = data.withUnsafeBytes { rawBuffer -> WhiteoutBridge.WOImageDecodeResult in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }

        XCTAssertEqual(error, WhiteoutBridge.WOError.None, "DDS decoding failed")
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.DDS)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(result.compression, WhiteoutBridge.WOImageCompression.Raw)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 2 * 2 * 4)
    }

    func testDDSUncompressedBGRADecodeInMemory() {
        // 手工拼接的 BGRA 字节替换为 writer round-trip 夹具
        // (WhiteoutLib DDS writer 输出 BGRA 排列,parser 解码时交换为 RGBA)。
        let bytes = WhiteoutBridge.WOEncodeTestImage(4, 4, 2)
        XCTAssertGreaterThan(bytes.size(), 0)
        var data = Data(bytes)
        var error = WhiteoutBridge.WOError.None
        var decoder = WhiteoutBridge.WOTextureDecoder()
        let result = data.withUnsafeBytes { rawBuffer -> WhiteoutBridge.WOImageDecodeResult in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }

        XCTAssertEqual(error, WhiteoutBridge.WOError.None, "DDS decoding failed")
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.DDS)
        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.compression, WhiteoutBridge.WOImageCompression.Raw)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 4 * 4 * 4)
    }

}
