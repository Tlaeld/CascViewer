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
        // Build a minimal 4x4 BLP2 raw (uncompressed) file in memory
        var bytes = [UInt8]()
        // Magic
        bytes.append(contentsOf: [0x42, 0x4C, 0x50, 0x32])
        // type = 1 (Direct)
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        // compression = 1, alphaDepth = 8, alphaType = 0, hasMips = 0
        bytes.append(contentsOf: [0x01, 0x08, 0x00, 0x00])
        // width = 4, height = 4
        bytes.append(contentsOf: [0x04, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x04, 0x00, 0x00, 0x00])
        // mipmapOffsets[16] — offset 0 = 148 (header size)
        bytes.append(contentsOf: [0x94, 0x00, 0x00, 0x00])
        for _ in 1..<16 { bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) }
        // mipmapSizes[16] — size 0 = 64 (4*4*4 bytes RGBA)
        bytes.append(contentsOf: [0x40, 0x00, 0x00, 0x00])
        for _ in 1..<16 { bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) }
        // Pixel data: 4x4 RGBA, solid red
        for _ in 0..<16 { bytes.append(contentsOf: [0xFF, 0x00, 0x00, 0xFF]) }

        let data = Data(bytes)
        var decoder = CascBridge.ImageDecoderBridge()
        var error = CascBridge.CascError.None
        let result = data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }

        XCTAssertEqual(error, CascBridge.CascError.None, "Decoding failed")
        XCTAssertEqual(result.format, CascBridge.ImageFormat.BLP2)
        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.compression, CascBridge.ImageCompression.Raw)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 64)
    }

    func testDDSUncompressedBGRADecodeRealFile() throws {
        let path = "/Users/ales/Desktop/mods/heroes.stormmod/eses.stormassets/assets/textures/storm_ui_hud_volskaya_overtime_text.dds"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real DDS file not found at \(path)")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            XCTFail("Failed to read DDS file")
            return
        }

        var decoder = CascBridge.ImageDecoderBridge()
        var error = CascBridge.CascError.None
        let result = data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }

        XCTAssertEqual(error, CascBridge.CascError.None, "Real DDS decoding failed")
        XCTAssertEqual(result.format, CascBridge.ImageFormat.DDS)
        XCTAssertEqual(result.width, 208)
        XCTAssertEqual(result.height, 72)
        XCTAssertEqual(result.compression, CascBridge.ImageCompression.Raw)
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

    func testDDSUncompressed24BitBGRDecodeInMemory() {
        // Build a minimal 2x2 DDS uncompressed 24-bit BGR file in memory
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
        appendU32(2)          // height
        appendU32(2)          // width
        appendU32(8)          // pitch = 8 (4-byte aligned, padded from 6)
        appendU32(0)          // depth
        appendU32(0)          // mipmaps
        for _ in 0..<11 { appendU32(0) }
        // Pixel format
        appendU32(32)         // pfSize
        appendU32(0x40)       // pfFlags: DDPF_RGB only
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // pfFourCC
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

        // Pixel data: 2x2 BGR (no alpha), 8-byte pitch with 2-byte padding per row
        // Row 0: Blue(FF0000), Green(00FF00), pad, pad
        bytes.append(contentsOf: [0xFF, 0x00, 0x00])
        bytes.append(contentsOf: [0x00, 0xFF, 0x00])
        bytes.append(contentsOf: [0x00, 0x00])
        // Row 1: Red(0000FF), Black(000000), pad, pad
        bytes.append(contentsOf: [0x00, 0x00, 0xFF])
        bytes.append(contentsOf: [0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x00, 0x00])

        let data = Data(bytes)
        var decoder = CascBridge.ImageDecoderBridge()
        var error = CascBridge.CascError.None
        let result = data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }

        XCTAssertEqual(error, CascBridge.CascError.None, "24-bit DDS decoding failed")
        XCTAssertEqual(result.format, CascBridge.ImageFormat.DDS)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(result.compression, CascBridge.ImageCompression.Raw)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 16)

        let rgba = result.frames[0].rgbaData
        // Pixel (0,0): Blue in BGR -> RGBA(00, 00, FF, FF)
        XCTAssertEqual(rgba[0], 0x00)
        XCTAssertEqual(rgba[1], 0x00)
        XCTAssertEqual(rgba[2], 0xFF)
        XCTAssertEqual(rgba[3], 0xFF)
        // Pixel (1,0): Green in BGR -> RGBA(00, FF, 00, FF)
        XCTAssertEqual(rgba[4], 0x00)
        XCTAssertEqual(rgba[5], 0xFF)
        XCTAssertEqual(rgba[6], 0x00)
        XCTAssertEqual(rgba[7], 0xFF)
        // Pixel (0,1): Red in BGR -> RGBA(FF, 00, 00, FF)
        XCTAssertEqual(rgba[8], 0xFF)
        XCTAssertEqual(rgba[9], 0x00)
        XCTAssertEqual(rgba[10], 0x00)
        XCTAssertEqual(rgba[11], 0xFF)
        // Pixel (1,1): Black in BGR -> RGBA(00, 00, 00, FF)
        XCTAssertEqual(rgba[12], 0x00)
        XCTAssertEqual(rgba[13], 0x00)
        XCTAssertEqual(rgba[14], 0x00)
        XCTAssertEqual(rgba[15], 0xFF)
    }

    func testDDSUncompressedBGRADecodeInMemory() {
        // Build a minimal 2x2 DDS uncompressed BGRA file in memory
        var bytes = [UInt8]()

        // Helper to append little-endian uint32
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
        // dwSize: 124
        appendU32(124)
        // dwFlags: DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_PITCH
        appendU32(0x0008100F)
        // dwHeight: 2
        appendU32(2)
        // dwWidth: 2
        appendU32(2)
        // dwPitchOrLinearSize: 8 (2 pixels * 4 bytes)
        appendU32(8)
        // dwDepth: 0
        appendU32(0)
        // dwMipMapCount: 0
        appendU32(0)
        // dwReserved1[11]
        for _ in 0..<11 { appendU32(0) }
        // Pixel format (32 bytes)
        appendU32(32)           // pfSize
        appendU32(0x41)         // pfFlags: DDPF_RGB | DDPF_ALPHAPIXELS
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // pfFourCC
        appendU32(32)           // pfRGBBitCount
        appendU32(0x00FF0000)   // pfRBitMask
        appendU32(0x0000FF00)   // pfGBitMask
        appendU32(0x000000FF)   // pfBBitMask
        appendU32(0xFF000000)   // pfABitMask
        // dwCaps: DDSCAPS_TEXTURE
        appendU32(0x1000)
        // dwCaps2, dwCaps3, dwCaps4, dwReserved2
        appendU32(0)
        appendU32(0)
        appendU32(0)
        appendU32(0)

        XCTAssertEqual(bytes.count, 128, "DDS header should be 128 bytes")

        // Pixel data: 2x2 BGRA
        // Row 0: Blue(FF0000FF), Green(00FF00FF)
        bytes.append(contentsOf: [0xFF, 0x00, 0x00, 0xFF])
        bytes.append(contentsOf: [0x00, 0xFF, 0x00, 0xFF])
        // Row 1: Red(0000FFFF), White(FFFFFFFF)
        bytes.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        let data = Data(bytes)
        var decoder = CascBridge.ImageDecoderBridge()
        var error = CascBridge.CascError.None
        let result = data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }

        XCTAssertEqual(error, CascBridge.CascError.None, "DDS decoding failed")
        XCTAssertEqual(result.format, CascBridge.ImageFormat.DDS)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(result.compression, CascBridge.ImageCompression.Raw)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 16)

        // Verify BGRA -> RGBA swap
        let rgba = result.frames[0].rgbaData
        // Pixel (0,0): Blue in BGRA -> RGBA(00, 00, FF, FF)
        XCTAssertEqual(rgba[0], 0x00)
        XCTAssertEqual(rgba[1], 0x00)
        XCTAssertEqual(rgba[2], 0xFF)
        XCTAssertEqual(rgba[3], 0xFF)
        // Pixel (1,0): Green in BGRA -> RGBA(00, FF, 00, FF)
        XCTAssertEqual(rgba[4], 0x00)
        XCTAssertEqual(rgba[5], 0xFF)
        XCTAssertEqual(rgba[6], 0x00)
        XCTAssertEqual(rgba[7], 0xFF)
        // Pixel (0,1): Red in BGRA -> RGBA(FF, 00, 00, FF)
        XCTAssertEqual(rgba[8], 0xFF)
        XCTAssertEqual(rgba[9], 0x00)
        XCTAssertEqual(rgba[10], 0x00)
        XCTAssertEqual(rgba[11], 0xFF)
        // Pixel (1,1): White in BGRA -> RGBA(FF, FF, FF, FF)
        XCTAssertEqual(rgba[12], 0xFF)
        XCTAssertEqual(rgba[13], 0xFF)
        XCTAssertEqual(rgba[14], 0xFF)
        XCTAssertEqual(rgba[15], 0xFF)
    }

}
