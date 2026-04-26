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
        XCTAssertEqual(entry.formattedSize, "1 KB")
    }

    @MainActor
    func testCASCSearchServiceWildcard() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let storageService = CASCStorageService(storage: storage)
        let searchService = CASCSearchService(storage: storageService)

        // Inject entries by directly setting (for testing only)
        storageService.entries = [
            CASCFileEntry(name: "tex1.blp", fullPath: "a/tex1.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "tex2.blp", fullPath: "a/tex2.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "model.mdx", fullPath: "a/model.mdx", type: .file, size: 100, encodingKey: "")
        ]

        let results = await searchService.search(query: "*.blp", in: "", useRegex: false)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.name.hasSuffix(".blp") })
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
}
