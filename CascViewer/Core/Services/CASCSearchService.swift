import Foundation

actor CASCSearchService {
    private let storage: CASCStorageService

    init(storage: CASCStorageService) {
        self.storage = storage
    }

    func search(query: String, in path: String, useRegex: Bool = false) async -> [CASCFileEntry] {
        return await storage.searchEntriesAsync(query: query, in: path, useRegex: useRegex)
    }
}
