import XCTest
@testable import CascViewer

final class CascViewerTests: XCTestCase {
    func testCASCErrorLocalizedDescriptionsAreNonEmpty() {
        let errors: [CASCError] = [
            .invalidPath, .storageNotFound, .storageCorrupted, .fileNotFound,
            .fileNotAvailable, .readError, .networkError, .cdnConfigError,
            .decodingError, .cancelled, .unknown, .notImplemented
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty, "\(error) should have a non-empty description")
        }
    }

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

    func testHexPatternParserValid() {
        XCTAssertEqual(HexPatternParser.parse("48 65 6C"), [0x48, 0x65, 0x6C])
        XCTAssertEqual(HexPatternParser.parse("48??6C"), [0x48, nil, 0x6C])
        XCTAssertEqual(HexPatternParser.parse("48 ? 6C"), [0x48, nil, 0x6C])
    }

    func testHexPatternParserInvalid() {
        XCTAssertNil(HexPatternParser.parse(""))
        XCTAssertNil(HexPatternParser.parse("G1"))
        XCTAssertNil(HexPatternParser.parse("4"))
    }

    func testSearchTagSystemBitMask() {
        let tags = [CascTag(name: "a", value: 0), CascTag(name: "b", value: 1)]
        let mask = SearchTagSystem.bitMask(for: tags, selected: ["a", "b"])
        XCTAssertEqual(mask, 0b11)
    }

    // MARK: - Model Tests (from BridgeTests)

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
