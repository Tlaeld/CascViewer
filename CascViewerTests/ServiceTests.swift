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
    func testCASCStorageServiceEntryLookup() {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCStorageService(storage: storage)
        service.allEntries = [
            CASCFileEntry(name: "a.txt", fullPath: "dir/a.txt", type: .file, size: 10, encodingKey: ""),
            CASCFileEntry(name: "b.txt", fullPath: "dir/b.txt", type: .file, size: 20, encodingKey: "")
        ]
        let (childrenMap, entriesByPath) = CASCStorageService.buildChildrenMap(from: service.allEntries)
        service.childrenByPath = childrenMap
        service.entriesByPath = entriesByPath

        let entry = service.entry(forPath: "dir/a.txt")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "a.txt")

        let under = service.entriesUnder(path: "dir")
        XCTAssertEqual(under.count, 2)
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

    @MainActor
    func testCASCExtractServiceEmptyEntries() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCExtractService(storage: storage)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = await service.extract(entries: [], to: dest, preserveStructure: false)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertTrue(result.failedFiles.isEmpty)
    }

    @MainActor
    func testCASCExtractServiceCancellation() async {
        let storage = CascBridge.CascStorageHandle.createLocal()
        let service = CASCExtractService(storage: storage)
        service.cancel()
        XCTAssertTrue(service.isCancelled)
    }

    // MARK: - CDNProductService Tests

    @MainActor
    func testCDNProductServiceInitialState() {
        let service = CDNProductService()
        XCTAssertFalse(service.isLoading)
        XCTAssertTrue(service.products.count > 0)
        XCTAssertNil(service.selectedProduct)
        XCTAssertTrue(service.selectedRegion.isEmpty)
    }

    @MainActor
    func testCDNProductSelectProduct() {
        let service = CDNProductService()
        guard let product = service.products.first else {
            XCTFail("Expected at least one built-in product")
            return
        }
        service.selectProduct(product)
        XCTAssertEqual(service.selectedProduct?.code, product.code)
        XCTAssertEqual(service.selectedRegion, product.regions.first ?? "")
    }

    @MainActor
    func testCDNProductBuiltInList() {
        let products = CDNProduct.builtInList
        XCTAssertFalse(products.isEmpty)
        // Verify codes are unique (stable ids)
        let codes = products.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count)
    }
}
