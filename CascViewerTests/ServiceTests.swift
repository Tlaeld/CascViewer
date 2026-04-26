import XCTest
import CascBridge
@testable import CascViewer

final class ServiceTests: XCTestCase {
    @MainActor
    func testCASCStorageServiceLocalOpen() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)

        await service.openLocal(path: "/nonexistent")
        XCTAssertNotNil(service.error)
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
        let searchService = CASCSearchService(storage: storageService)

        let results = await searchService.search(query: "*.blp", in: "", useRegex: false)
        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testCASCExtractServiceInitialState() {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCExtractService(storage: storage)
        XCTAssertFalse(service.isExtracting)
        XCTAssertEqual(service.progress, 0)
    }
}
