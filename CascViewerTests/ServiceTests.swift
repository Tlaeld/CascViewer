import XCTest
import CascBridge
@testable import CascViewer

final class ServiceTests: XCTestCase {
    @MainActor
    func testCASCStorageServiceLocalOpen() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)

        await service.openLocal(path: "/nonexistent")
        XCTAssertEqual(service.error, .storageNotFound)
    }

    @MainActor
    func testCASCStorageServiceInitialState() {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertNil(service.storageInfo)
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testCASCSearchService() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let storageService = CASCStorageService(storage: storage)
        let searchService = CASCSearchService(handle: storageService.handle)

        let request = SearchRequest(mode: .filename, query: "*.blp", scope: .entireStorage, caseSensitive: false, useRegex: false, includePath: false, fileTypes: [], selectedTags: [], availableTags: [])
        let results = await searchService.search(request, allEntries: [], entries: [], currentPath: "")
        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testCASCSearchServiceRegex() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let storageService = CASCStorageService(storage: storage)
        let searchService = CASCSearchService(handle: storageService.handle)

        let testEntries = [
            CASCFileEntry(name: "tex1.blp", fullPath: "a/tex1.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "tex2.blp", fullPath: "a/tex2.blp", type: .file, size: 100, encodingKey: "")
        ]

        let request = SearchRequest(mode: .filename, query: ".*\\.blp", scope: .entireStorage, caseSensitive: false, useRegex: true, includePath: false, fileTypes: [], selectedTags: [], availableTags: [])
        let results = await searchService.search(request, allEntries: testEntries, entries: testEntries, currentPath: "")
        XCTAssertEqual(results.count, 2)
    }

    @MainActor
    func testCASCExtractServiceInitialState() {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCExtractService(storage: storage)
        XCTAssertFalse(service.isExtracting)
        XCTAssertEqual(service.progress, 0)
    }
}
