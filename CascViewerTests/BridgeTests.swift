import XCTest
import CascBridge
@testable import CascViewer

final class BridgeTests: XCTestCase {
    func testCascStorageHandleOpenInvalidPath() {
        var storage = CascBridge.CascStorageHandle.createLocal()
        let error = storage.open(std.string("/nonexistent/path"))
        XCTAssertNotEqual(error, CascBridge.CascError.None)
    }

    func testCASCFileEntryModel() {
        let entry = CASCFileEntry(
            name: "test.blp",
            fullPath: "textures/test.blp",
            type: .file,
            size: 1024,
            encodingKey: "abc123"
        )
        XCTAssertEqual(entry.name, "test.blp")
        XCTAssertFalse(entry.isDirectory)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        XCTAssertEqual(entry.formattedSize, formatter.string(fromByteCount: 1024))
    }

    @MainActor
    func testCASCSearchServiceWildcard() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let storageService = CASCStorageService(storage: storage)
        let searchService = CASCSearchService(handle: storageService.handle)

        // Inject entries by directly setting (for testing only)
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

    func testCASCFileEntryDirectorySize() {
        let entry = CASCFileEntry(
            name: "Data",
            fullPath: "Data",
            type: .directory,
            size: 0,
            encodingKey: ""
        )
        XCTAssertTrue(entry.isDirectory)
        XCTAssertEqual(entry.formattedSize, "--")
    }

    func testCASCErrorAllCasesHaveDescriptions() {
        let errors: [CASCError] = [.invalidPath, .storageNotFound, .storageCorrupted, .fileNotFound, .readError, .networkError, .cdnConfigError, .decodingError, .unknown, .notImplemented]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testBLPImageInfo() {
        let info = BLPImageInfo(
            format: .blp2,
            width: 512,
            height: 512,
            mipLevels: 11,
            frameCount: 1,
            hasAlpha: true
        )
        XCTAssertEqual(info.mipLevels, 11)
        XCTAssertTrue(info.hasAlpha)
    }

    func testCASCErrorLocalizedDescription() {
        let error = CASCError.storageNotFound
        XCTAssertEqual(error.localizedDescription, "Storage not found at the specified path.")
    }

    func testCASCStorageInfo() {
        let info = CASCStorageInfo(
            productName: "WoW",
            buildVersion: "10.2.5",
            totalFiles: 1000,
            totalSize: 1024 * 1024 * 1024
        )
        XCTAssertEqual(info.productName, "WoW")
        XCTAssertEqual(info.totalFiles, 1000)
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


}
