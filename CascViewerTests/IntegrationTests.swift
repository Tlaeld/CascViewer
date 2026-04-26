import XCTest
import CascBridge
@testable import CascViewer

final class IntegrationTests: XCTestCase {
    @MainActor
    func testAppLaunch() {
        let appState = AppState()
        XCTAssertNil(appState.currentStorage)
        XCTAssertEqual(appState.selectedPath, "")
        XCTAssertFalse(appState.isLoading)
    }

    @MainActor
    func testServiceLifecycle() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)

        // Initial state
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertNil(service.storageInfo)

        // Open invalid storage
        await service.openLocal(path: "/nonexistent/path/that/does/not/exist")
        XCTAssertNotNil(service.error)

        // Close resets state
        service.close()
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertNil(service.storageInfo)
    }

    func testBLPDecodeResultModel() {
        let frame = BLPDecodeResult.BLPFrame(width: 256, height: 256, imageData: Data(repeating: 0, count: 256 * 256 * 4))
        XCTAssertEqual(frame.width, 256)
        XCTAssertEqual(frame.height, 256)
        XCTAssertEqual(frame.imageData.count, 256 * 256 * 4)
    }

    @MainActor
    func testSearchWithEmptyEntries() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let storageService = CASCStorageService(storage: storage)
        let searchService = CASCSearchService(storage: storageService)

        let results = await searchService.search(query: "*.blp", in: "", useRegex: false)
        XCTAssertTrue(results.isEmpty)
    }

    func testCASCFileEntryEquality() {
        let entry1 = CASCFileEntry(name: "test.blp", fullPath: "a/test.blp", type: .file, size: 100, encodingKey: "abc")
        let entry2 = CASCFileEntry(name: "test.blp", fullPath: "a/test.blp", type: .file, size: 100, encodingKey: "abc")
        XCTAssertEqual(entry1, entry2)
        XCTAssertEqual(entry1.hashValue, entry2.hashValue)
    }
}
