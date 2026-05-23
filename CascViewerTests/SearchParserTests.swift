import XCTest
import CascBridge
@testable import CascViewer

final class SearchParserTests: XCTestCase {

    // MARK: - HexPatternParser

    func testHexPatternParserSpaceSeparated() {
        XCTAssertEqual(HexPatternParser.parse("48 65 6C"), [0x48, 0x65, 0x6C])
    }

    func testHexPatternParserWildcards() {
        XCTAssertEqual(HexPatternParser.parse("48 ?? 6C"), [0x48, nil, 0x6C])
        XCTAssertEqual(HexPatternParser.parse("48 ? 6C"), [0x48, nil, 0x6C])
    }

    func testHexPatternParserContinuous() {
        XCTAssertEqual(HexPatternParser.parse("48656C"), [0x48, 0x65, 0x6C])
    }

    func testHexPatternParserContinuousWildcards() {
        XCTAssertEqual(HexPatternParser.parse("48??6C"), [0x48, nil, 0x6C])
        XCTAssertEqual(HexPatternParser.parse("48?6C"), [0x48, nil, 0x6C])
    }

    func testHexPatternParserMixedWildcards() {
        XCTAssertEqual(HexPatternParser.parse("48??6C6C6F"), [0x48, nil, 0x6C, 0x6C, 0x6F])
    }

    func testHexPatternParserInvalid() {
        XCTAssertNil(HexPatternParser.parse("GG HH"))
        XCTAssertNil(HexPatternParser.parse("4"))
        XCTAssertNil(HexPatternParser.parse(""))
        XCTAssertNil(HexPatternParser.parse("   "))
    }

    func testHexPatternParserEdgeCases() {
        // Leading wildcard in continuous string
        XCTAssertEqual(HexPatternParser.parse("?48"), [nil, 0x48])
        // Trailing wildcard in continuous string
        XCTAssertEqual(HexPatternParser.parse("48?"), [0x48, nil])
        // Odd-length string should fail
        XCTAssertNil(HexPatternParser.parse("486"))
        // Single wildcard only
        XCTAssertEqual(HexPatternParser.parse("?"), [nil])
    }

    func testHexPatternParserSingleByte() {
        XCTAssertEqual(HexPatternParser.parse("FF"), [0xFF])
    }

    func testHexPatternParserCaseInsensitive() {
        XCTAssertEqual(HexPatternParser.parse("ff ee"), [0xFF, 0xEE])
        XCTAssertEqual(HexPatternParser.parse("Ff Ee"), [0xFF, 0xEE])
    }

    // MARK: - SearchTagSystem

    func testTagBitMasks() {
        let tags = [
            CascTag(name: "Texture", value: 0),
            CascTag(name: "Audio", value: 1),
            CascTag(name: "Model", value: 2)
        ]
        let map = SearchTagSystem.tagBitMasks(from: tags)
        XCTAssertEqual(map["Texture"], 1)
        XCTAssertEqual(map["Audio"], 2)
        XCTAssertEqual(map["Model"], 4)
    }

    func testBitMask() {
        let tags = [
            CascTag(name: "Texture", value: 0),
            CascTag(name: "Audio", value: 1),
            CascTag(name: "Model", value: 2)
        ]
        let mask = SearchTagSystem.bitMask(for: tags, selected: ["Texture", "Model"])
        XCTAssertEqual(mask, 0b101)
    }

    func testBitMaskEmptySelection() {
        let tags = [CascTag(name: "Texture", value: 0)]
        let mask = SearchTagSystem.bitMask(for: tags, selected: [])
        XCTAssertEqual(mask, 0)
    }

    func testBitMaskUnknownTag() {
        let tags = [CascTag(name: "Texture", value: 0)]
        let mask = SearchTagSystem.bitMask(for: tags, selected: ["NonExistent"])
        XCTAssertEqual(mask, 0)
    }

    // MARK: - isSafeRegexPattern

    func testSafeRegexPatterns() {
        XCTAssertTrue(CASCStorageService.isSafeRegexPattern("hello"))
        XCTAssertTrue(CASCStorageService.isSafeRegexPattern(".*\\.blp"))
        XCTAssertTrue(CASCStorageService.isSafeRegexPattern("[a-z]+"))
        XCTAssertTrue(CASCStorageService.isSafeRegexPattern("^start$"))
    }

    func testUnsafeRegexPatterns() {
        XCTAssertFalse(CASCStorageService.isSafeRegexPattern("(a+)+"))
        XCTAssertFalse(CASCStorageService.isSafeRegexPattern("(a*)*"))
        XCTAssertFalse(CASCStorageService.isSafeRegexPattern("(a+)*"))
        XCTAssertFalse(CASCStorageService.isSafeRegexPattern("(a*)+"))
        XCTAssertFalse(CASCStorageService.isSafeRegexPattern("((a+)?)+"))
    }

    func testRegexPatternLengthLimit() {
        let longPattern = String(repeating: "a", count: 300)
        XCTAssertFalse(CASCStorageService.isSafeRegexPattern(longPattern))
    }

    // MARK: - findHexPattern

    func testFindHexPatternBasic() {
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(CASCSearchService.findHexPattern([0x48, 0x65], in: data), 0)
        XCTAssertEqual(CASCSearchService.findHexPattern([0x6C, 0x6C], in: data), 2)
        XCTAssertEqual(CASCSearchService.findHexPattern([0x6F], in: data), 4)
    }

    func testFindHexPatternWithWildcard() {
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual(CASCSearchService.findHexPattern([0x48, nil, 0x6C], in: data), 0)
        XCTAssertEqual(CASCSearchService.findHexPattern([nil, 0x65, 0x6C], in: data), 0)
    }

    func testFindHexPatternNotFound() {
        let data = Data([0x48, 0x65, 0x6C])
        XCTAssertNil(CASCSearchService.findHexPattern([0xFF], in: data))
    }

    func testFindHexPatternEmpty() {
        let data = Data([0x48])
        XCTAssertNil(CASCSearchService.findHexPattern([], in: data))
    }

    // MARK: - rangeOfCaseInsensitive

    func testRangeOfCaseInsensitiveASCII() {
        let data = Data("Hello World".utf8)
        let range = CASCSearchService.rangeOfCaseInsensitive("hello", in: data)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 0)
        XCTAssertEqual(range?.upperBound, 5)
    }

    func testRangeOfCaseInsensitiveNotFound() {
        let data = Data("Hello World".utf8)
        let range = CASCSearchService.rangeOfCaseInsensitive("xyz", in: data)
        XCTAssertNil(range)
    }

    func testRangeOfCaseInsensitiveMixedCase() {
        let data = Data("HeLLo WoRLd".utf8)
        let range = CASCSearchService.rangeOfCaseInsensitive("hello", in: data)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 0)
        XCTAssertEqual(range?.upperBound, 5)
    }

    func testRangeOfCaseInsensitiveASCIIFallback() {
        // Invalid UTF-8 data with ASCII needle
        let data = Data([0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xFE])
        let range = CASCSearchService.rangeOfCaseInsensitive("hello", in: data)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 1)
        XCTAssertEqual(range?.upperBound, 6)
    }

    // MARK: - filterByTypes

    func testFilterByTypes() {
        let entries = [
            CASCFileEntry(name: "tex1.blp", fullPath: "a/tex1.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "tex2.dds", fullPath: "a/tex2.dds", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "model.mdx", fullPath: "a/model.mdx", type: .file, size: 100, encodingKey: "")
        ]
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let filtered = service.filterByTypes(entries, ["BLP", "DDS"])
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.name.hasSuffix(".blp") || $0.name.hasSuffix(".dds") })
    }

    func testFilterByTypesEmptySet() {
        let entries = [
            CASCFileEntry(name: "file.txt", fullPath: "file.txt", type: .file, size: 100, encodingKey: "")
        ]
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let filtered = service.filterByTypes(entries, [])
        XCTAssertEqual(filtered.count, 1)
    }

    // MARK: - getCandidates

    func testGetCandidatesEntireStorage() {
        let entries = [
            CASCFileEntry(name: "a.txt", fullPath: "a.txt", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "b.txt", fullPath: "dir/b.txt", type: .file, size: 100, encodingKey: "")
        ]
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let candidates = service.getCandidates(scope: .entireStorage, allEntries: entries, entries: [], currentPath: "")
        XCTAssertEqual(candidates.count, 2)
    }

    func testGetCandidatesCurrentDirectory() {
        let entries = [
            CASCFileEntry(name: "a.txt", fullPath: "dir/a.txt", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "b.txt", fullPath: "other/b.txt", type: .file, size: 100, encodingKey: "")
        ]
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let candidates = service.getCandidates(scope: .currentDirectory, allEntries: entries, entries: [], currentPath: "dir")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.name, "a.txt")
    }

    func testGetCandidatesCurrentDirectoryRoot() {
        let entries = [
            CASCFileEntry(name: "a.txt", fullPath: "a.txt", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "b.txt", fullPath: "dir/b.txt", type: .file, size: 100, encodingKey: "")
        ]
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let candidates = service.getCandidates(scope: .currentDirectory, allEntries: entries, entries: [], currentPath: "")
        XCTAssertEqual(candidates.count, 2)
    }

    func testGetCandidatesFallsBackToEntries() {
        let entries = [
            CASCFileEntry(name: "a.txt", fullPath: "a.txt", type: .file, size: 100, encodingKey: "")
        ]
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let candidates = service.getCandidates(scope: .entireStorage, allEntries: [], entries: entries, currentPath: "")
        XCTAssertEqual(candidates.count, 1)
    }

    // MARK: - Search mode boundary tests (no real storage)

    @MainActor
    func testSearchContentEmptyQuery() async {
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let request = SearchRequest(mode: .content, query: "", scope: .entireStorage, caseSensitive: false, useRegex: false, includePath: false, fileTypes: [], selectedTags: [], availableTags: [])
        let results = await service.search(request, allEntries: [], entries: [], currentPath: "")
        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testSearchHexInvalidPattern() async {
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let request = SearchRequest(mode: .hex, query: "GG HH", scope: .entireStorage, caseSensitive: false, useRegex: false, includePath: false, fileTypes: [], selectedTags: [], availableTags: [])
        let results = await service.search(request, allEntries: [], entries: [], currentPath: "")
        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testSearchTagNoMatch() async {
        let service = CASCSearchService(handle: CascBridge.CascStorageHandle.createLocal())
        let request = SearchRequest(mode: .tag, query: "NonExistent", scope: .entireStorage, caseSensitive: false, useRegex: false, includePath: false, fileTypes: [], selectedTags: [], availableTags: [])
        let results = await service.search(request, allEntries: [], entries: [], currentPath: "")
        XCTAssertTrue(results.isEmpty)
    }
}
