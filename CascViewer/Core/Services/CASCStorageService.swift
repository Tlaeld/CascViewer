import Foundation
import Combine
import CascBridge

private func localizedProgressMessage(_ cMessage: UnsafePointer<CChar>) -> String {
    let message = String(cString: cMessage)
    switch message {
    case "Loading file": return L("progress_loading_file")
    case "Loading manifest": return L("progress_loading_manifest")
    case "Downloading file": return L("progress_downloading_file")
    case "Loading indexes": return L("progress_loading_indexes")
    case "Downloading archive indexes": return L("progress_downloading_archive_indexes")
    default: return message
    }
}

// C-style callback thunk for C++ progress callback
private let progressCallbackThunk: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, CInt, CInt) -> Void = { context, message, current, total in
    guard let ctx = context, let msg = message else { return }
    let service = Unmanaged<CASCStorageService>.fromOpaque(ctx).takeUnretainedValue()
    let localizedMsg = localizedProgressMessage(msg)
    DispatchQueue.main.async {
        if Date().timeIntervalSince(service.lastProgressUpdate) > 0.05 {
            service.lastProgressUpdate = Date()
            service.loadProgressMessage = localizedMsg
            if total > 0 {
                service.loadProgress = Double(current) / Double(total)
            }
            // When total == 0, keep the previous progress to avoid flickering
            // back to indeterminate spinner between phases
        }
    }
}

public struct DirectoryNode: Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public var children: [DirectoryNode]? = nil
    public let isLocal: Bool

    public init(name: String, path: String, children: [DirectoryNode]? = nil, isLocal: Bool = true) {
        self.name = name
        self.path = path
        self.children = children
        self.isLocal = isLocal
    }

    init(from entry: CASCFileEntry) {
        self.name = entry.name
        self.path = entry.fullPath
        self.children = entry.isDirectory ? [] : nil
        self.isLocal = entry.isLocal
    }

    public static func == (lhs: DirectoryNode, rhs: DirectoryNode) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

@MainActor
final class CASCStorageService: ObservableObject {
    @Published var currentPath: String = ""
    @Published var entries: [CASCFileEntry] = []
    @Published var currentChildren: [DirectoryNode] = []
    @Published var storageInfo: CASCStorageInfo?
    @Published var isLoading = false
    @Published var loadProgress: Double = 0
    @Published var loadProgressMessage: String = ""
    @Published var error: CASCError?
    @Published var lastProgressUpdate: Date = Date.distantPast

    var handle: CascBridge.CascStorageHandle
    private let queue = DispatchQueue(label: "casc.storage", qos: .userInitiated)
    private var allEntries: [CASCFileEntry] = []
    private(set) var childrenByPath: [String: [DirectoryNode]] = [:]
    private var entriesByPath: [String: CASCFileEntry] = [:]
    private var directoryPaths: Set<String> = []
    var allEntriesCount: Int { allEntries.count }

    init(storage: CascBridge.CascStorageHandle) {
        self.handle = storage
    }

    deinit {
        handle.close()
    }

    func openLocal(path: String) async {
        guard !isLoading else { return }
        isLoading = true
        loadProgress = 0
        loadProgressMessage = L("loading_storage")
        error = nil
        print("[CASC] " + L("loading_storage") + ": \(path)")
        var localHandle = handle
        localHandle.setCdnDownloadEnabled(AppSettings.shared.cdnDownloadEnabled)
        localHandle.setOpenProgressCallback(progressCallbackThunk, Unmanaged.passUnretained(self).toOpaque())
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
            queue.async {
                let result = localHandle.open(std.string(path))
                continuation.resume(returning: result)
            }
        }
        // Keep the final progress from CascLib (likely 1.0) instead of resetting to 0
        if result != .None {
            loadProgressMessage = ""
            isLoading = false
            self.error = mapError(result)
        } else {
            await refreshStorageInfo()
            await loadRootEntries()
            isLoading = false
            loadProgressMessage = ""
        }
    }

    func openOnline(product: String, region: String) async {
        guard !isLoading else { return }
        isLoading = true
        loadProgress = 0
        loadProgressMessage = L("loading_storage")
        error = nil
        let config = "\(product):\(region)"
        var localHandle = handle
        localHandle.setOpenProgressCallback(progressCallbackThunk, Unmanaged.passUnretained(self).toOpaque())
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CascBridge.CascError, Never>) in
            queue.async {
                let result = localHandle.open(std.string(config))
                continuation.resume(returning: result)
            }
        }
        loadProgress = 0
        if result != .None {
            loadProgressMessage = ""
            isLoading = false
            self.error = mapError(result)
        } else {
            await refreshStorageInfo()
            await loadRootEntries()
            isLoading = false
            loadProgressMessage = ""
        }
    }

    /// Load root entries once from C++ and cache them. All heavy work is done on background queue.
    /// Note: caller is responsible for setting/clearing `isLoading`.
    private func loadRootEntries() async {
        loadProgressMessage = L("building_children_map")
        // Reset progress to 0 so the overlay shows an indeterminate spinner
        // instead of a stuck progress bar during this phase.
        loadProgress = 0
        var localHandle = handle
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<([CASCFileEntry], [String: [DirectoryNode]], CascBridge.CascError), Never>) in
            queue.async {
                var error = CascBridge.CascError.None
                let rawEntries = localHandle.listDirectory(std.string(""), &error)
                let mapped = (0..<rawEntries.size()).map { i in
                    let entry = rawEntries[i]
                    return CASCFileEntry(
                        name: String(entry.name),
                        fullPath: String(entry.fullPath),
                        type: entry.type == .File ? .file : .directory,
                        size: entry.size,
                        encodingKey: String(entry.encodingKey),
                        isLocal: entry.isLocal
                    )
                }
                print("[CASC] " + L("building_children_map"))
                let childrenMap = Self.buildChildrenMap(from: mapped)
                print("[CASC] " + L("built_children_map", childrenMap.count))
                continuation.resume(returning: (mapped, childrenMap, error))
            }
        }
        print("[CASC] loadRootEntries continuation resumed")
        loadProgressMessage = ""
        let (newEntries, childrenMap, err) = result
        if err != .None {
            self.error = mapError(err)
        } else {
            self.allEntries = newEntries
            self.entriesByPath = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.normalizedPath, $0) })
            self.directoryPaths = Set(childrenMap.keys)
            self.childrenByPath = childrenMap
            self.currentPath = ""
            self.currentChildren = childrenMap[""] ?? []
            self.entries = []
            print("[CASC] " + L("load_root_entries_done", newEntries.count))
        }
    }

    /// Pre-compute a map from every directory path to its direct children.
    /// This makes navigation O(1) instead of O(n) over all entries.
    nonisolated static func buildChildrenMap(from entries: [CASCFileEntry]) -> [String: [DirectoryNode]] {
        var dirNamesByPath: [String: Set<String>] = [:]
        var fileNodesByPath: [String: [DirectoryNode]] = [:]
        var dirHasLocalFiles = Set<String>()

        for entry in entries {
            let normalized = entry.normalizedPath
            let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { continue }

            // Register intermediate directories with incremental path building
            var currentPath = ""
            for i in 0..<(components.count - 1) {
                let dirName = String(components[i])
                dirNamesByPath[currentPath, default: Set()].insert(dirName)
                currentPath = currentPath.isEmpty ? dirName : currentPath + "/" + dirName
            }

            // Register the file at its parent path
            let parentPath = currentPath
            let name = String(components[components.count - 1])
            fileNodesByPath[parentPath, default: []].append(
                DirectoryNode(name: name, path: normalized, children: nil, isLocal: entry.isLocal)
            )

            // Propagate local-file flag up the directory tree
            if entry.isLocal {
                var dirPath = ""
                for i in 0..<(components.count - 1) {
                    let component = String(components[i])
                    dirPath = dirPath.isEmpty ? component : dirPath + "/" + component
                    dirHasLocalFiles.insert(dirPath)
                }
            }
        }

        var map: [String: [DirectoryNode]] = [:]
        for (path, dirNames) in dirNamesByPath {
            var children: [DirectoryNode] = []
            for dirName in dirNames {
                let dirPath = path.isEmpty ? dirName : path + "/" + dirName
                let isLocal = dirHasLocalFiles.contains(dirPath)
                children.append(DirectoryNode(name: dirName, path: dirPath, children: [], isLocal: isLocal))
            }
            map[path] = children
        }

        for (path, files) in fileNodesByPath {
            let dirNameSet = dirNamesByPath[path] ?? []
            var children = map[path, default: []]
            for file in files {
                if !dirNameSet.contains(file.name) {
                    children.append(file)
                }
            }
            map[path] = children
        }
        return map
    }

    /// Compute direct children for a given path. Runs on caller's queue.
    nonisolated static func computeChildren(for path: String, from entries: [CASCFileEntry]) -> [DirectoryNode] {
        let prefix = path.isEmpty ? "" : path + "/"
        var dirs = Set<String>()
        var dirNodes = [DirectoryNode]()
        var fileNodes = [DirectoryNode]()
        var dirHasLocalFiles = Set<String>()

        for entry in entries {
            let normalized = entry.normalizedPath
            guard normalized.hasPrefix(prefix) else { continue }
            let remainder = String(normalized.dropFirst(prefix.count))
            let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first else { continue }
            let name = String(first)

            if components.count == 1 {
                fileNodes.append(DirectoryNode(name: name, path: normalized, children: nil, isLocal: entry.isLocal))
                if entry.isLocal {
                    dirHasLocalFiles.insert(prefix + name)
                }
            } else if dirs.insert(name).inserted {
                let dirPath = prefix + name
                dirNodes.append(DirectoryNode(name: name, path: dirPath, children: nil))
            }

            // Also propagate local flag to parent directories
            if entry.isLocal && components.count > 1 {
                let dirPath = prefix + name
                dirHasLocalFiles.insert(dirPath)
            }
        }

        let dirsWithLocal = dirNodes.map {
            DirectoryNode(name: $0.name, path: $0.path, children: nil, isLocal: dirHasLocalFiles.contains($0.path))
        }
        return (dirsWithLocal + fileNodes).sorted { $0.name < $1.name }
    }

    /// Pure in-memory navigation — O(1) lookup via pre-computed map.
    func navigate(to path: String) {
        self.currentPath = path
        self.currentChildren = childrenByPath[path, default: []]
    }

    /// Search all cached entries on background queue.
    /// Matches against the full path so directory names are searchable too.
    func searchEntriesAsync(query: String, in path: String, useRegex: Bool) async -> [CASCFileEntry] {
        let localEntries = allEntries.isEmpty ? entries : allEntries
        return await withCheckedContinuation { continuation in
            queue.async {
                let prefix = path.isEmpty ? "" : path + "/"
                let candidates = localEntries.filter { $0.normalizedPath.hasPrefix(prefix) }
                let searchText = query.lowercased()
                let results: [CASCFileEntry]
                if useRegex {
                    guard let regex = try? NSRegularExpression(pattern: query, options: .caseInsensitive) else {
                        continuation.resume(returning: [])
                        return
                    }
                    results = candidates.filter { entry in
                        let range = NSRange(entry.normalizedPath.startIndex..., in: entry.normalizedPath)
                        return regex.firstMatch(in: entry.normalizedPath, options: [], range: range) != nil
                    }
                } else if !query.contains("*") && !query.contains("?") {
                    // Fast path: simple substring match on full path
                    results = candidates.filter { entry in
                        entry.normalizedPath.lowercased().contains(searchText)
                    }
                } else {
                    let pattern = query
                        .replacingOccurrences(of: "*", with: ".*")
                        .replacingOccurrences(of: "?", with: ".")
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                        continuation.resume(returning: [])
                        return
                    }
                    results = candidates.filter { entry in
                        let range = NSRange(entry.normalizedPath.startIndex..., in: entry.normalizedPath)
                        return regex.firstMatch(in: entry.normalizedPath, options: [], range: range) != nil
                    }
                }
                continuation.resume(returning: results)
            }
        }
    }

    func entry(forPath path: String) -> CASCFileEntry? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return entriesByPath[normalized]
    }

    /// Return all file entries under a given directory path (recursive).
    func entriesUnder(path: String) -> [CASCFileEntry] {
        let prefix = path.isEmpty ? "" : path + "/"
        return allEntries.filter { $0.normalizedPath.hasPrefix(prefix) }
    }

    func close() {
        handle.close()
        entries = []
        allEntries = []
        currentChildren = []
        currentPath = ""
        storageInfo = nil
        entriesByPath = [:]
        directoryPaths = []
    }

    private func refreshStorageInfo() async {
        var localHandle = handle
        let (info, err) = await withCheckedContinuation { (continuation: CheckedContinuation<(CascBridge.CascStorageInfo, CascBridge.CascError), Never>) in
            queue.async {
                var error = CascBridge.CascError.None
                let info = localHandle.getStorageInfo(&error)
                continuation.resume(returning: (info, error))
            }
        }
        if err == .None {
            self.storageInfo = CASCStorageInfo(
                productName: String(info.productName),
                buildVersion: String(info.buildVersion),
                totalFiles: info.totalFiles,
                totalSize: 0
            )
        }
    }

    private func mapError(_ error: CascBridge.CascError) -> CASCError {
        switch error {
        case .InvalidPath: return .invalidPath
        case .StorageNotFound: return .storageNotFound
        case .StorageCorrupted: return .storageCorrupted
        case .FileNotFound: return .fileNotFound
        case .ReadError: return .readError
        case .NetworkError: return .networkError
        case .CDNConfigError: return .cdnConfigError
        case .DecodingError: return .decodingError
        default: return .unknown
        }
    }
}
