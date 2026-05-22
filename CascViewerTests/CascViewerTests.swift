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
        XCTAssertEqual(HexPatternParser.parse("48 65 6C")?.compactMap { $0 }, [0x48, 0x65, 0x6C])
        XCTAssertEqual(HexPatternParser.parse("48??6C")?.compactMap { $0 }, [0x48, nil, 0x6C])
        XCTAssertEqual(HexPatternParser.parse("48 ? 6C")?.compactMap { $0 }, [0x48, nil, 0x6C])
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
}
