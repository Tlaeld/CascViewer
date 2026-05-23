import XCTest
@testable import CascViewer

final class SearchPreviewTests: XCTestCase {

    // MARK: - makePreview (UTF-8 text)

    func testMakePreviewBasic() {
        let data = Data("Hello World".utf8)
        let matchRange = data.range(of: Data("World".utf8))!
        let preview = CASCSearchService.makePreview(data: data, matchRange: matchRange, queryLength: 5)

        XCTAssertEqual(preview.match, "World")
        XCTAssertEqual(preview.prefix, "Hello ")
    }

    func testMakePreviewMultibyteUTF8() {
        // "你好世界" with search for "世界"
        let text = "你好世界"
        let data = Data(text.utf8)
        let searchText = "世界"
        let matchRange = data.range(of: Data(searchText.utf8))!

        let preview = CASCSearchService.makePreview(data: data, matchRange: matchRange, queryLength: Data(searchText.utf8).count)

        XCTAssertEqual(preview.match, "世界")
        XCTAssertEqual(preview.prefix, "你好")
    }

    func testMakePreviewTruncation() {
        let longText = String(repeating: "a", count: 100) + "MATCH" + String(repeating: "b", count: 100)
        let data = Data(longText.utf8)
        let matchRange = data.range(of: Data("MATCH".utf8))!
        let preview = CASCSearchService.makePreview(data: data, matchRange: matchRange, queryLength: 5)

        // Total preview should be trimmed to around 50 chars
        let totalLength = preview.prefix.count + preview.match.count + preview.suffix.count
        XCTAssertLessThanOrEqual(totalLength, 52) // 50 + some margin for ellipsis
        XCTAssertTrue(preview.prefix.hasPrefix("…") || preview.prefix.count < 50)
    }

    func testMakePreviewAtStart() {
        let data = Data("MATCH followed by text".utf8)
        let matchRange = data.range(of: Data("MATCH".utf8))!
        let preview = CASCSearchService.makePreview(data: data, matchRange: matchRange, queryLength: 5)

        XCTAssertEqual(preview.match, "MATCH")
        XCTAssertEqual(preview.prefix, "")
    }

    func testMakePreviewAtEnd() {
        let data = Data("text before MATCH".utf8)
        let matchRange = data.range(of: Data("MATCH".utf8))!
        let preview = CASCSearchService.makePreview(data: data, matchRange: matchRange, queryLength: 5)

        XCTAssertEqual(preview.match, "MATCH")
        XCTAssertEqual(preview.suffix, "")
    }

    // MARK: - makePreview (non-UTF-8, hex fallback)

    func testMakePreviewHexFallback() {
        // Use invalid UTF-8 sequence to force hex fallback path
        let data = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8, 0xF7, 0xF6])
        let matchRange = 3..<5 // match bytes 0xFC, 0xFB
        let preview = CASCSearchService.makePreview(data: data, matchRange: matchRange, queryLength: 2)

        XCTAssertTrue(preview.match.contains("FC"))
        XCTAssertTrue(preview.match.contains("FB"))
        XCTAssertTrue(preview.prefix.contains("FD"))
        XCTAssertTrue(preview.suffix.contains("FA"))
    }

    // MARK: - makeHexPreview

    func testMakeHexPreview() {
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64])
        let preview = CASCSearchService.makeHexPreview(data: data, offset: 6, patternLength: 5)

        // Context: 6 bytes before and after, but limited by data bounds
        XCTAssertTrue(preview.match.contains("57"))
        XCTAssertTrue(preview.match.contains("6F"))
        XCTAssertTrue(preview.prefix.contains("48") || preview.prefix.contains("65"))
    }

    func testMakeHexPreviewAtStart() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        let preview = CASCSearchService.makeHexPreview(data: data, offset: 0, patternLength: 2)

        XCTAssertEqual(preview.prefix, "")
        XCTAssertTrue(preview.match.contains("00"))
        XCTAssertTrue(preview.match.contains("01"))
    }

    func testMakeHexPreviewAtEnd() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        let preview = CASCSearchService.makeHexPreview(data: data, offset: 4, patternLength: 2)

        XCTAssertTrue(preview.match.contains("04"))
        XCTAssertTrue(preview.match.contains("05"))
        XCTAssertEqual(preview.suffix, "")
    }
}
