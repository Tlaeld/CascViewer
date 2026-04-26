import XCTest
import CascBridge
@testable import CascViewer

final class IntegrationTests: XCTestCase {
    @MainActor
    func testAppStateStorageBinding() {
        let appState = AppState()
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)

        appState.currentStorage = service
        XCTAssertNotNil(appState.currentStorage)

        service.entries = [
            CASCFileEntry(name: "test.blp", fullPath: "test.blp", type: .file, size: 100, encodingKey: "abc")
        ]
        XCTAssertEqual(appState.currentStorage?.entries.count, 1)
    }

    @MainActor
    func testStorageSearchIntegration() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let storageService = CASCStorageService(storage: storage)
        let searchService = CASCSearchService(storage: storageService)

        storageService.entries = [
            CASCFileEntry(name: "tex1.blp", fullPath: "a/tex1.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "tex2.blp", fullPath: "a/tex2.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "model.mdx", fullPath: "a/model.mdx", type: .file, size: 100, encodingKey: "")
        ]

        let results = await searchService.search(query: "*.blp", in: "", useRegex: false)
        XCTAssertEqual(results.count, 2)
    }

    @MainActor
    func testBLPDecodeIntegration() async {
        let coordinator = BLPDecoderCoordinator()

        // Empty data should throw
        do {
            _ = try await coordinator.decode(data: Data())
            XCTFail("Expected decoding error for empty data")
        } catch {
            // Expected
        }
    }

    @MainActor
    func testExtractServiceLifecycle() {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let extractService = CASCExtractService(storage: storage)

        XCTAssertFalse(extractService.isExtracting)
        XCTAssertEqual(extractService.progress, 0)
    }
}
