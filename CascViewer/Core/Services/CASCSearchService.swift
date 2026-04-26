import Foundation

actor CASCSearchService {
    private let storage: CASCStorageService

    init(storage: CASCStorageService) {
        self.storage = storage
    }

    func search(query: String, in path: String, useRegex: Bool = false) async -> [CASCFileEntry] {
        let allEntries = await storage.entries
        if useRegex {
            guard let regex = try? NSRegularExpression(pattern: query, options: .caseInsensitive) else {
                return []
            }
            return allEntries.filter { entry in
                let range = NSRange(entry.name.startIndex..., in: entry.name)
                return regex.firstMatch(in: entry.name, options: [], range: range) != nil
            }
        } else {
            let pattern = query
                .replacingOccurrences(of: "*", with: ".*")
                .replacingOccurrences(of: "?", with: ".")
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: .caseInsensitive) else {
                return []
            }
            return allEntries.filter { entry in
                let range = NSRange(entry.name.startIndex..., in: entry.name)
                return regex.firstMatch(in: entry.name, options: [], range: range) != nil
            }
        }
    }
}
