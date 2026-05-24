import XCTest
@testable import CascViewer

final class CascViewerTests: XCTestCase {
    func testCASCFileEntryNormalizedPath() {
        let entry = CASCFileEntry(
            name: "test.txt",
            fullPath: "folder\\test.txt",
            type: .file,
            size: 100,
            encodingKey: "abc123"
        )
        XCTAssertEqual(entry.normalizedPath, "folder/test.txt")
    }

    func testSearchModeIdentifiable() {
        for mode in SearchMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    // MARK: - Model Tests

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

    func testCASCErrorLocalizedDescription() {
        let error = CASCError.storageNotFound
        let description = error.localizedDescription
        XCTAssertFalse(description.isEmpty)
        XCTAssertTrue(description.contains("Storage") || description.contains("storage"))
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
}
