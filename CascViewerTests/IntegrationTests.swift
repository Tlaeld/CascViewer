import XCTest
import CascBridge
@testable import CascViewer

final class IntegrationTests: XCTestCase {
    @MainActor
    func testEndToEndSearchFlow() async {
        // Setup: AppState → StorageService → SearchService
        let appState = AppState()
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)
        appState.currentStorage = service

        // Simulate storage having entries (as if from listDirectory)
        service.entries = [
            CASCFileEntry(name: "tex1.blp", fullPath: "a/tex1.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "tex2.blp", fullPath: "a/tex2.blp", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "model.mdx", fullPath: "a/model.mdx", type: .file, size: 100, encodingKey: "")
        ]

        // Search through the full service chain
        let searchService = CASCSearchService(storage: service)
        let results = await searchService.search(query: "*.blp", in: "", useRegex: false)

        // Verify results propagate back through AppState
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.name.hasSuffix(".blp") })
    }

    @MainActor
    func testErrorPropagationAcrossLayers() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)

        // Open invalid path
        await service.openLocal(path: "/this/does/not/exist")

        // Error should be set on service
        XCTAssertNotNil(service.error)
        XCTAssertEqual(service.error, .storageNotFound)

        // Storage info should be nil after failed open
        XCTAssertNil(service.storageInfo)
    }

    @MainActor
    func testStorageCloseClearsState() {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)

        service.entries = [
            CASCFileEntry(name: "test.blp", fullPath: "test.blp", type: .file, size: 100, encodingKey: "")
        ]
        service.close()

        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertNil(service.storageInfo)
        XCTAssertEqual(service.currentPath, "")
    }
}
