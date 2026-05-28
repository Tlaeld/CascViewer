import Foundation
import CascBridge

@MainActor
final class CDNProductService: ObservableObject {
    @Published var products: [CDNProduct] = []
    @Published var selectedProduct: CDNProduct? = nil
    @Published var selectedRegion: String = ""
    @Published var isLoading = false
    @Published var cachePath: String = ""


    private static let cacheFileURL: URL = {
        let fm = FileManager.default
        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            // Fallback to temporary directory if caches directory is unavailable
            return fm.temporaryDirectory.appendingPathComponent("CascViewer/regions_cache.json")
        }
        return cachesDir.appendingPathComponent("CascViewer/regions_cache.json")
    }()

    init() {
        self.cachePath = AppSettings.shared.cdnCachePath
        self.products = CDNProduct.builtInList
        loadCachedRegions()
    }

    var hasCachedRegions: Bool {
        products.contains { !$0.regions.isEmpty }
    }

    func loadRegions(maxConcurrent: Int = 10) async {
        isLoading = true
        defer {
            isLoading = false
            saveCachedRegions()
        }

        await withTaskGroup(of: (Int, [String]).self) { group in
            var launchedCount = 0

            // Launch up to maxConcurrent initial tasks
            for (index, product) in products.enumerated() {
                if Task.isCancelled { break }
                products[index].isLoading = true
                group.addTask {
                    let regions = await CDNProductService.fetchRegions(for: product.code)
                    return (index, regions)
                }
                launchedCount += 1
                if launchedCount >= maxConcurrent { break }
            }

            // Consume results and backfill new tasks to keep concurrency bounded
            for await (index, regions) in group {
                if index < products.count {
                    products[index].regions = regions
                    products[index].loadFailed = regions.isEmpty
                    products[index].isLoading = false
                }

                if launchedCount < products.count && !Task.isCancelled {
                    let nextIndex = launchedCount
                    products[nextIndex].isLoading = true
                    group.addTask {
                        let regions = await CDNProductService.fetchRegions(for: self.products[nextIndex].code)
                        return (nextIndex, regions)
                    }
                    launchedCount += 1
                }
            }
        }

        if Task.isCancelled { return }
        if selectedProduct == nil || selectedProduct?.regions.isEmpty == true {
            if let first = products.first(where: { !$0.regions.isEmpty }) {
                selectedProduct = first
                selectedRegion = first.regions.first ?? ""
            }
        }
    }

    private func loadCachedRegions() {
        let url = Self.cacheFileURL
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        for i in products.indices {
            if let regions = dict[products[i].code] {
                products[i].regions = regions
            }
        }
    }

    private func saveCachedRegions() {
        // Snapshot current state to avoid capturing self across isolation boundaries
        let snapshot: [String: [String]] = products.reduce(into: [:]) { dict, product in
            if !product.regions.isEmpty {
                dict[product.code] = product.regions
            }
        }
        let url = Self.cacheFileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                // Cache save failed; best-effort, log for debugging
                print("Failed to save CDN product cache: \(error)")
            }
        }
    }

    func reloadSelectedProduct() async {
        guard let product = selectedProduct,
              let index = products.firstIndex(where: { $0.id == product.id }) else {
            return
        }

        // Skip if already loaded
        if !products[index].regions.isEmpty {
            return
        }

        products[index].isLoading = true
        defer {
            products[index].isLoading = false
            saveCachedRegions()
        }

        // Use a detached concurrent path so this doesn't block behind
        // the serial queue used by loadRegions().
        let regions: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let regions = CascBridge.CascStorageHandle.fetchProductRegions(std.string(product.code))
                var result: [String] = []
                for region in regions {
                    result.append(String(region))
                }
                continuation.resume(returning: result)
            }
        }
        // Regions reloaded

        if index < products.count {
            products[index].regions = regions
            products[index].loadFailed = regions.isEmpty
        }

        // Update selected product reference since products array changed
        if let updated = products.first(where: { $0.id == product.id }) {
            selectedProduct = updated
            if !updated.regions.isEmpty && !updated.regions.contains(selectedRegion) {
                selectedRegion = updated.regions.first ?? ""
            }
        }
    }

    func selectProduct(_ product: CDNProduct) {
        selectedProduct = product
        selectedRegion = product.regions.first ?? ""
    }

    private nonisolated static func fetchRegions(for code: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let regions = CascBridge.CascStorageHandle.fetchProductRegions(std.string(code))
                var result: [String] = []
                for region in regions {
                    result.append(String(region))
                }
                continuation.resume(returning: result)
            }
        }
    }

    func saveCachePath() {
        AppSettings.shared.cdnCachePath = cachePath
    }
}
