import Foundation
import CascBridge

struct CascTag: Equatable {
    let name: String
    let value: UInt32
}

enum SearchMode: String, CaseIterable, Identifiable {
    case filename = "filename"
    case content = "content"
    case hex = "hex"
    case tag = "tag"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .filename: return L("search_mode_filename")
        case .content: return L("search_mode_content")
        case .hex: return L("search_mode_hex")
        case .tag: return L("search_mode_tag")
        }
    }

    var placeholder: String {
        switch self {
        case .filename: return L("search_placeholder_filename")
        case .content: return L("search_placeholder_content")
        case .hex: return L("search_placeholder_hex")
        case .tag: return L("search_placeholder_tag")
        }
    }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case entireStorage = "entire"
    case currentDirectory = "current"

    var id: String { rawValue }
}

struct SearchRequest {
    let mode: SearchMode
    let query: String
    let scope: SearchScope
    let caseSensitive: Bool
    let useRegex: Bool
    let includePath: Bool
    let fileTypes: Set<String>
    let selectedTags: Set<String>
    let availableTags: [CascTag]
}

struct SearchMatchPreview: Equatable {
    let prefix: String
    let match: String
    let suffix: String
}

struct SearchMatch: Identifiable, Equatable {
    let entry: CASCFileEntry
    let preview: SearchMatchPreview?
    let offset: Int?

    var id: String { entry.id }
}

enum SearchSortBy: String, CaseIterable, Identifiable {
    case name, size, path
    var id: String { rawValue }
}

// MARK: - Hex Pattern Parser

enum HexPatternParser {
    static func parse(_ input: String) -> [UInt8?]? {
        var result: [UInt8?] = []
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(" ") {
            // Space-separated (e.g. "48 65 6C" or "48 ?? 6C")
            for token in trimmed.split(separator: " ") {
                let hex = String(token)
                if hex == "?" || hex == "??" {
                    result.append(nil)
                } else if let byte = UInt8(hex, radix: 16) {
                    result.append(byte)
                } else {
                    return nil
                }
            }
        } else {
            // Continuous string with possible ?? or ? wildcards
            var i = trimmed.startIndex
            while i < trimmed.endIndex {
                let remaining = trimmed.distance(from: i, to: trimmed.endIndex)

                // Try ?? wildcard first (2 chars)
                if remaining >= 2 {
                    let j = trimmed.index(i, offsetBy: 2)
                    let twoChars = String(trimmed[i..<j])
                    if twoChars == "??" {
                        result.append(nil)
                        i = j
                        continue
                    }
                }

                // Try ? wildcard (1 char)
                if remaining >= 1 {
                    let j = trimmed.index(i, offsetBy: 1)
                    let oneChar = String(trimmed[i..<j])
                    if oneChar == "?" {
                        result.append(nil)
                        i = j
                        continue
                    }
                }

                // Try hex byte (2 chars)
                if remaining >= 2 {
                    let j = trimmed.index(i, offsetBy: 2)
                    let twoChars = String(trimmed[i..<j])
                    if let byte = UInt8(twoChars, radix: 16) {
                        result.append(byte)
                        i = j
                    } else {
                        return nil
                    }
                } else {
                    return nil
                }
            }
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Tag System

struct SearchTagSystem {
    /// Build a tag-to-bitmask map from CascLib tags.
    static func tagBitMasks(from tags: [CascTag]) -> [String: UInt64] {
        var map: [String: UInt64] = [:]
        for tag in tags {
            map[tag.name] = (1 as UInt64) << UInt64(tag.value)
        }
        return map
    }

    static func bitMask(for tags: [CascTag], selected: Set<String>) -> UInt64 {
        var mask: UInt64 = 0
        let map = tagBitMasks(from: tags)
        for name in selected {
            if let bit = map[name] {
                mask |= bit
            }
        }
        return mask
    }
}

// MARK: - Search Service

class CASCSearchService {
    private var handle: CascBridge.CascStorageHandle
    private let maxContentReadSize = 10 * 1024 * 1024 // 10MB cap per file
    private let maxConcurrentSearches = ProcessInfo.processInfo.processorCount

    init(handle: CascBridge.CascStorageHandle) {
        self.handle = handle
    }

    func search(_ request: SearchRequest, allEntries: [CASCFileEntry], entries: [CASCFileEntry], currentPath: String) async -> [SearchMatch] {
        let candidates = getCandidates(scope: request.scope, allEntries: allEntries, entries: entries, currentPath: currentPath)

        let results: [SearchMatch]
        switch request.mode {
        case .filename:
            results = await searchFilename(request: request, candidates: candidates)
        case .content:
            results = await searchContent(request: request, candidates: candidates)
        case .hex:
            results = await searchHex(request: request, candidates: candidates)
        case .tag:
            results = await searchTag(request: request, candidates: candidates)
        }

        // Apply tag filter if any tags are selected
        if !request.selectedTags.isEmpty {
            let tagMask = SearchTagSystem.bitMask(for: request.availableTags, selected: request.selectedTags)
            if tagMask != 0 {
                return results.filter { ($0.entry.tagBitMask & tagMask) != 0 }
            }
        }
        return results
    }

    // MARK: - Filename Search

    private func searchFilename(request: SearchRequest, candidates: [CASCFileEntry]) async -> [SearchMatch] {
        let query = request.query
        guard !query.isEmpty else { return [] }

        let caseSensitive = request.caseSensitive
        let useRegex = request.useRegex
        let includePath = request.includePath
        let filteredByType = filterByTypes(candidates, request.fileTypes)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results: [SearchMatch]

                if useRegex {
                    guard CASCStorageService.isSafeRegexPattern(query) else {
                        continuation.resume(returning: [])
                        return
                    }
                    let options: NSRegularExpression.Options = caseSensitive ? [] : .caseInsensitive
                    guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                        continuation.resume(returning: [])
                        return
                    }
                    results = filteredByType.compactMap { entry in
                        let matchText = includePath
                            ? String(entry.normalizedPath.prefix(4096))
                            : String(entry.name.prefix(4096))
                        let range = NSRange(matchText.startIndex..., in: matchText)
                        guard regex.firstMatch(in: matchText, options: [], range: range) != nil else { return nil }
                        return SearchMatch(entry: entry, preview: nil, offset: nil)
                    }
                } else if query.contains("*") || query.contains("?") {
                    let pattern = query
                        .replacingOccurrences(of: "*", with: ".*")
                        .replacingOccurrences(of: "?", with: ".")
                    guard CASCStorageService.isSafeRegexPattern(pattern),
                          let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : .caseInsensitive) else {
                        continuation.resume(returning: [])
                        return
                    }
                    results = filteredByType.compactMap { entry in
                        let matchText = includePath
                            ? String(entry.normalizedPath.prefix(4096))
                            : String(entry.name.prefix(4096))
                        let range = NSRange(matchText.startIndex..., in: matchText)
                        guard regex.firstMatch(in: matchText, options: [], range: range) != nil else { return nil }
                        return SearchMatch(entry: entry, preview: nil, offset: nil)
                    }
                } else {
                    let searchText = caseSensitive ? query : query.lowercased()
                    results = filteredByType.compactMap { entry in
                        let text = includePath
                            ? (caseSensitive ? entry.normalizedPath : entry.normalizedPath.lowercased())
                            : (caseSensitive ? entry.name : entry.name.lowercased())
                        guard text.contains(searchText) else { return nil }
                        return SearchMatch(entry: entry, preview: nil, offset: nil)
                    }
                }

                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - Content Search (parallel with TaskGroup)

    private func searchContent(request: SearchRequest, candidates: [CASCFileEntry]) async -> [SearchMatch] {
        let query = request.query
        guard !query.isEmpty else { return [] }

        let filteredByType = filterByTypes(candidates, request.fileTypes)
        // Sort small files first for faster initial results; skip unavailable remote files
        let targetFiles = filteredByType
            .filter { !$0.isDirectory && $0.size > 0 && $0.isLocal }
            .sorted { $0.size < $1.size }

        let searchText = request.caseSensitive ? query : query.lowercased()
        let caseSensitive = request.caseSensitive
        let maxRead: UInt64 = 64 * 1024  // Only read first 64KB - most text matches are in the header
        var localHandle = handle

        return await withTaskGroup(of: SearchMatch?.self) { group in
            var results: [SearchMatch] = []
            var activeCount = 0

            for entry in targetFiles {
                if activeCount >= maxConcurrentSearches {
                    if let match = await group.next() {
                        if let match = match { results.append(match) }
                    }
                    activeCount -= 1
                }

                group.addTask {
                    if Task.isCancelled { return nil }

                    var error = CascBridge.CascError.None
                    let buffer = localHandle.readFilePartial(
                        std.string(entry.normalizedPath),
                        0,
                        maxRead,
                        &error
                    )
                    guard error == .None else { return nil }

                    if Task.isCancelled { return nil }

                    let searchSpace = Data(buffer)
                    guard !searchSpace.isEmpty else { return nil }

                    let range: Range<Data.Index>?
                    if caseSensitive {
                        range = searchSpace.range(of: Data(searchText.utf8))
                    } else {
                        // Fast path: search lowercase text in lowercase ASCII bytes
                        range = Self.rangeOfCaseInsensitive(searchText, in: searchSpace)
                    }

                    guard let foundRange = range else { return nil }

                    let offset = foundRange.lowerBound
                    let matchByteLength = foundRange.upperBound - foundRange.lowerBound
                    let preview = Self.makePreview(data: searchSpace, matchRange: foundRange, queryLength: matchByteLength)
                    return SearchMatch(entry: entry, preview: preview, offset: offset)
                }

                activeCount += 1
            }

            for await match in group {
                if let match = match { results.append(match) }
            }

            return results
        }
    }

    /// Fast case-insensitive byte search. Converts both needle and haystack to lowercase ASCII.
    /// Falls back to UTF-8 string comparison for non-ASCII content.
    internal static func rangeOfCaseInsensitive(_ needle: String, in haystack: Data) -> Range<Data.Index>? {
        let needleData = Data(needle.utf8)
        let needleLower = Data(needle.lowercased().utf8)

        // Fast path: if haystack is valid UTF-8 and mostly ASCII, lowercase the whole thing
        if let text = String(data: haystack, encoding: .utf8) {
            let lowerData = Data(text.lowercased().utf8)
            return lowerData.range(of: needleLower)
        }

        // Fallback: raw byte comparison with uppercase needle too
        if let range = haystack.range(of: needleData) {
            return range
        }
        return haystack.range(of: Data(needle.uppercased().utf8))
    }

    // MARK: - Hex Search (parallel with TaskGroup)

    private func searchHex(request: SearchRequest, candidates: [CASCFileEntry]) async -> [SearchMatch] {
        guard let pattern = HexPatternParser.parse(request.query) else { return [] }
        guard !pattern.isEmpty else { return [] }

        let filteredByType = filterByTypes(candidates, request.fileTypes)
        let targetFiles = filteredByType.filter { !$0.isDirectory && $0.size > 0 }

        let maxRead = maxContentReadSize
        var localHandle = handle

        return await withTaskGroup(of: SearchMatch?.self) { group in
            var results: [SearchMatch] = []
            var activeCount = 0

            for entry in targetFiles {
                if activeCount >= maxConcurrentSearches {
                    if let match = await group.next() {
                        if let match = match { results.append(match) }
                    }
                    activeCount -= 1
                }

                group.addTask {
                    if Task.isCancelled { return nil }

                    var error = CascBridge.CascError.None
                    let buffer = localHandle.readFilePartial(
                        std.string(entry.normalizedPath),
                        0,
                        UInt64(maxRead),
                        &error
                    )
                    guard error == .None else { return nil }

                    if Task.isCancelled { return nil }

                    let searchSpace = Data(buffer)
                    guard !searchSpace.isEmpty else { return nil }

                    guard let offset = Self.findHexPattern(pattern, in: searchSpace) else { return nil }

                    let preview = Self.makeHexPreview(data: searchSpace, offset: offset, patternLength: pattern.count)
                    return SearchMatch(entry: entry, preview: preview, offset: offset)
                }

                activeCount += 1
            }

            for await match in group {
                if let match = match { results.append(match) }
            }

            return results
        }
    }

    // MARK: - Tag Search

    private func searchTag(request: SearchRequest, candidates: [CASCFileEntry]) async -> [SearchMatch] {
        guard !request.selectedTags.isEmpty else { return [] }

        let tagMask = SearchTagSystem.bitMask(for: request.availableTags, selected: request.selectedTags)
        guard tagMask != 0 else { return [] }

        let filteredByType = filterByTypes(candidates, request.fileTypes)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = filteredByType.compactMap { entry -> SearchMatch? in
                    guard (entry.tagBitMask & tagMask) != 0 else { return nil }
                    return SearchMatch(entry: entry, preview: nil, offset: nil)
                }
                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - Helpers

    internal func getCandidates(scope: SearchScope, allEntries: [CASCFileEntry], entries: [CASCFileEntry], currentPath: String) -> [CASCFileEntry] {
        let all = allEntries.isEmpty ? entries : allEntries
        switch scope {
        case .entireStorage:
            return all
        case .currentDirectory:
            let prefix = currentPath.isEmpty ? "" : currentPath + "/"
            return all.filter { $0.normalizedPath.hasPrefix(prefix) }
        }
    }

    internal func filterByTypes(_ entries: [CASCFileEntry], _ types: Set<String>) -> [CASCFileEntry] {
        guard !types.isEmpty else { return entries }
        return entries.filter { entry in
            let ext = (entry.name as NSString).pathExtension.uppercased()
            return types.contains(ext)
        }
    }

    internal static func findHexPattern(_ pattern: [UInt8?], in data: Data) -> Int? {
        guard !pattern.isEmpty else { return nil }
        let firstByte = pattern[0]

        for i in 0..<data.count {
            if let first = firstByte, data[i] != first { continue }

            var matched = true
            for j in 0..<pattern.count {
                let idx = i + j
                if idx >= data.count { matched = false; break }
                if let expected = pattern[j], data[idx] != expected {
                    matched = false
                    break
                }
            }
            if matched { return i }
        }
        return nil
    }

    internal static func makePreview(data: Data, matchRange: Range<Data.Index>, queryLength: Int) -> SearchMatchPreview {
        let totalMaxChars = 50
        let contextBeforeChars = 18
        let contextAfterChars = 18

        let start = max(0, matchRange.lowerBound - contextBeforeChars)
        let end = min(data.count, matchRange.upperBound + contextAfterChars)
        let slice = data[start..<end]

        if let text = String(data: slice, encoding: .utf8) {
            let matchStartInSlice = matchRange.lowerBound - start
            let matchEndInSlice = matchRange.upperBound - start

            // Convert byte offsets to String.Index using UTF-8 view
            let utf8View = text.utf8
            let startIdx = utf8View.index(utf8View.startIndex, offsetBy: matchStartInSlice)
            let endIdx = utf8View.index(utf8View.startIndex, offsetBy: matchEndInSlice)

            let prefix = String(text[..<startIdx])
            let match = String(text[startIdx..<endIdx])
            let suffix = String(text[endIdx...])

            let total = prefix.count + match.count + suffix.count
            if total > totalMaxChars {
                let excess = total - totalMaxChars
                let trimPrefix = min(excess / 2, prefix.count)
                let trimSuffix = min(excess - trimPrefix, suffix.count)
                let trimmedPrefix = prefix.count > trimPrefix ? "…" + String(prefix.dropFirst(trimPrefix)) : prefix
                let trimmedSuffix = suffix.count > trimSuffix ? String(suffix.dropLast(trimSuffix)) + "…" : suffix
                return SearchMatchPreview(prefix: trimmedPrefix, match: match, suffix: trimmedSuffix)
            }
            return SearchMatchPreview(prefix: prefix, match: match, suffix: suffix)
        } else {
            let matchStartInSlice = matchRange.lowerBound - start
            let matchEndInSlice = matchStartInSlice + queryLength
            let hexBytes = slice.map { String(format: "%02X", $0) }
            let prefixBytes = Array(hexBytes.prefix(matchStartInSlice))
            let matchBytes = Array(hexBytes[matchStartInSlice..<matchEndInSlice])
            let suffixBytes = Array(hexBytes.suffix(hexBytes.count - matchEndInSlice))
            return SearchMatchPreview(
                prefix: prefixBytes.joined(separator: " ") + (prefixBytes.isEmpty ? "" : " "),
                match: matchBytes.joined(separator: " "),
                suffix: (suffixBytes.isEmpty ? "" : " ") + suffixBytes.joined(separator: " ")
            )
        }
    }

    internal static func makeHexPreview(data: Data, offset: Int, patternLength: Int) -> SearchMatchPreview {
        let contextBytes = 6
        let start = max(0, offset - contextBytes)
        let end = min(data.count, offset + patternLength + contextBytes)
        let slice = data[start..<end]
        let hexBytes = slice.map { String(format: "%02X", $0) }

        let matchStartInSlice = offset - start
        let matchEndInSlice = matchStartInSlice + patternLength

        let prefix = Array(hexBytes.prefix(matchStartInSlice))
        let match = Array(hexBytes[matchStartInSlice..<matchEndInSlice])
        let suffix = Array(hexBytes.suffix(hexBytes.count - matchEndInSlice))

        return SearchMatchPreview(
            prefix: prefix.joined(separator: " ") + (prefix.isEmpty ? "" : " "),
            match: match.joined(separator: " "),
            suffix: (suffix.isEmpty ? "" : " ") + suffix.joined(separator: " ")
        )
    }
}
