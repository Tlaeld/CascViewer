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

/// Thread-safe box passed as the C++ progress callback context.
/// Holds the service reference and a non-actor-isolated throttle timestamp
/// so the callback can avoid creating a Task on every invocation.
private final class ProgressCallbackContext: @unchecked Sendable {
    let service: CASCStorageService
    private let lock = NSLock()
    private var _lastUpdate: Date = .distantPast
    var lastUpdate: Date {
        get { lock.lock(); defer { lock.unlock() }; return _lastUpdate }
        set { lock.lock(); defer { lock.unlock() }; _lastUpdate = newValue }
    }
    init(service: CASCStorageService) {
        self.service = service
    }
}

// C-style callback thunk for C++ progress callback
private let progressCallbackThunk: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, CInt, CInt) -> Void = { context, message, current, total in
    guard let ctx = context, let msg = message else { return }
    let box = Unmanaged<ProgressCallbackContext>.fromOpaque(ctx).takeUnretainedValue()
    let service = box.service
    let localizedMsg = localizedProgressMessage(msg)

    // Throttle on the callback thread before dispatching to MainActor.
    // safe because the C++ callback is serial on one background thread.
    let now = Date()
    if now.timeIntervalSince(box.lastUpdate) > 0.05 {
        box.lastUpdate = now
        Task { @MainActor in
            service.loadProgressMessage = localizedMsg
            if total > 0 {
                service.loadProgress = Double(current) / Double(total)
            }
            // When total == 0, keep the previous progress to avoid flickering
            // back to indeterminate spinner between phases
        }
    }
}

public struct DirectoryNode: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public var children: [DirectoryNode]? = nil
    public let isLocal: Bool
    public let size: UInt64
    public let hasChildDirectories: Bool
    public var iconName: String { Self.computeIconName(name: name, isDirectory: children != nil) }

    public var formattedSize: String {
        if children != nil { return "--" }
        guard let sizeInt64 = Int64(exactly: size) else { return "--" }
        return Self.byteFormatter.string(fromByteCount: sizeInt64)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    public init(name: String, path: String, children: [DirectoryNode]? = nil, isLocal: Bool = true, size: UInt64 = 0, hasChildDirectories: Bool = false) {
        self.name = name
        self.path = path
        self.children = children
        self.isLocal = isLocal
        self.size = size
        self.hasChildDirectories = hasChildDirectories
    }

    init(from entry: CASCFileEntry) {
        self.name = entry.name
        self.path = entry.fullPath
        let isDir = entry.isDirectory
        self.children = isDir ? [] : nil
        self.isLocal = entry.isLocal
        self.size = entry.size
        self.hasChildDirectories = false
    }

    public static func == (lhs: DirectoryNode, rhs: DirectoryNode) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    private static func computeIconName(name: String, isDirectory: Bool) -> String {
        guard !isDirectory else { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "strings", "json", "xml", "html", "csv":
            return "doc.text"
        case "blp", "dds", "tga", "png", "jpg", "jpeg":
            return "photo"
        case "mp3", "ogg", "wav", "flac":
            return "music.note"
        case "mp4", "avi", "mov", "mkv":
            return "film"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        case "exe", "dll", "so", "dylib":
            return "terminal"
        case "sc2data", "sc2assets", "sc2mod", "sc2campaign", "sc2components":
            return "cube.box"
        case "version":
            return "number"
        case "pdf":
            return "doc.richtext"
        case "lua", "js", "ts", "swift", "cpp", "h", "hpp", "c":
            return "curlybraces"
        default:
            return "doc"
        }
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
    // Throttle state lives in ProgressCallbackContext (non-actor-isolated)
    // to avoid Task creation overhead on every C++ progress callback.
    @Published var isOnlineStorage: Bool = false
    @Published var needsListFile: Bool = false

    var handle: CascBridge.CascStorageHandle
    private let queue = DispatchQueue(label: "casc.storage", qos: .userInitiated)
    private let group = DispatchGroup()
    var allEntries: [CASCFileEntry] = []
    internal var childrenByPath: [String: [DirectoryNode]] = [:]
    internal var entriesByPath: [String: CASCFileEntry] = [:]

    private var progressContext: UnsafeMutableRawPointer? = nil
    var allEntriesCount: Int { allEntries.count }
    var tags: [CascTag] = []

    init(storage: CascBridge.CascStorageHandle) {
        self.handle = storage
    }

    deinit {
        handle.setOpenProgressCallback(nil, nil)
        // Synchronously wait for any outstanding background work (runOnQueue)
        // and then close the storage. CascLib is not thread-safe; calling
        // CascCloseStorage from a detached Task while internal threads may
        // still be active causes assert failures in CASC_SOCKET_CACHE.
        let _ = group.wait(timeout: .now() + .seconds(5))
        handle.close()
    }

    /// Run work on a detached background task, tracking it with a DispatchGroup
    /// so `deinit` can wait for completion before closing the handle.
    /// Task.detached ensures the caller stays on its executor (MainActor) after the await.
    private func runOnQueue<T>(_ work: @escaping () -> T) async -> T {
        let g = group
        return await Task.detached(priority: .userInitiated) {
            g.enter()
            defer { g.leave() }
            return work()
        }.value
    }

    var listFilePath: String = ""
    
    func openLocal(path: String) async {
        guard !isLoading else { return }
        isLoading = true
        isOnlineStorage = false
        loadProgress = 0
        loadProgressMessage = L("loading_storage")
        error = nil
        
        var localHandle = handle
        localHandle.setCdnDownloadEnabled(AppSettings.shared.cdnDownloadEnabled)
        if !listFilePath.isEmpty {
            localHandle.setListFilePath(std.string(listFilePath))
        }
        let ctx = ProgressCallbackContext(service: self)
        let raw = Unmanaged.passRetained(ctx).toOpaque()
        progressContext = raw
        localHandle.setOpenProgressCallback(progressCallbackThunk, raw)
        let result: CascBridge.CascError = await runOnQueue {
            localHandle.open(std.string(path))
        }
        localHandle.setOpenProgressCallback(nil, nil)
        progressContext = nil
        Unmanaged<ProgressCallbackContext>.fromOpaque(raw).release()
        // Cooperative cancellation: if the task was cancelled while opening,
        // don't proceed to load entries and don't overwrite error state.
        guard !Task.isCancelled else {
            isLoading = false
            loadProgressMessage = ""
            return
        }
        // Keep the final progress from CascLib (likely 1.0) instead of resetting to 0
        if result != .None {
            loadProgressMessage = ""
            isLoading = false
            self.error = mapError(result)
        } else {
            await refreshStorageInfo()
            guard !Task.isCancelled else {
                isLoading = false
                loadProgressMessage = ""
                return
            }
            await loadRootEntries()
            guard !Task.isCancelled else {
                isLoading = false
                loadProgressMessage = ""
                return
            }
            await loadTags()
            isLoading = false
            loadProgressMessage = ""
        }
    }

    func openOnline(product: String, region: String) async {
        guard !isLoading else { return }
        isLoading = true
        isOnlineStorage = true
        loadProgress = 0
        loadProgressMessage = L("loading_storage")
        error = nil
        let baseCachePath = AppSettings.shared.cdnCachePath.isEmpty
            ? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("CascViewer").path ?? "")
            : AppSettings.shared.cdnCachePath
        // Use product-specific subfolder to avoid cache conflicts between different products
        let cachePath = (baseCachePath as NSString).appendingPathComponent(product)
        // Ensure cache directory exists before opening
        do {
            try FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true)
        } catch {
            self.error = .unknown
            loadProgressMessage = L("cache_directory_failed", error.localizedDescription)
            isLoading = false
            return
        }
        let config = "\(cachePath)*\(product)*\(region)"

        let result = await openWithConfig(config: config)

        // If cache is corrupted, clean it and retry once
        if result == .StorageCorrupted {
            // Cache corrupted, retrying
            let fm = FileManager.default
            let versionsFile = (cachePath as NSString).appendingPathComponent("versions")
            let cdnsFile = (cachePath as NSString).appendingPathComponent("cdns")
            try? fm.removeItem(atPath: versionsFile)
            try? fm.removeItem(atPath: cdnsFile)
            let retryResult = await openWithConfig(config: config)
            await handleOpenResult(retryResult)
            return
        }

        // If storage not found, it may be a transient CDN failure (rate limiting
        // or connection reset during bulk downloads). Retry with exponential backoff
        // so partial cache from earlier attempts can be reused.
        if result == .StorageNotFound {
            var retryResult = result
            for attempt in 1...3 {
                if Task.isCancelled {
                    await handleOpenResult(retryResult)
                    return
                }
                let waitSeconds = UInt64(3 * attempt)
                do {
                    try await Task.sleep(nanoseconds: waitSeconds * 1_000_000_000)
                } catch {
                    await handleOpenResult(retryResult)
                    return
                }
                retryResult = await openWithConfig(config: config)
                if retryResult == .None {
                    break
                }
            }
            await handleOpenResult(retryResult)
            return
        }

        await handleOpenResult(result)
    }

    private func handleOpenResult(_ result: CascBridge.CascError) async {
        loadProgress = 0
        if result != .None {
            loadProgressMessage = ""
            isLoading = false
            self.error = mapError(result)
        } else {
            await refreshStorageInfo()
            await loadRootEntries()
            await loadTags()
            isLoading = false
            loadProgressMessage = ""
        }
    }

    private func openWithConfig(config: String) async -> CascBridge.CascError {
        var localHandle = handle
        let ctx = ProgressCallbackContext(service: self)
        let raw = Unmanaged.passRetained(ctx).toOpaque()
        progressContext = raw
        localHandle.setOpenProgressCallback(progressCallbackThunk, raw)
        let result: CascBridge.CascError = await runOnQueue {
            localHandle.open(std.string(config))
        }
        localHandle.setOpenProgressCallback(nil, nil)
        progressContext = nil
        Unmanaged<ProgressCallbackContext>.fromOpaque(raw).release()
        return result
    }

    private func loadTags() async {
        guard !Task.isCancelled else { return }
        let rawTags: [CascTag] = await runOnQueue {
            let tags = self.handle.getTags()
            return (0..<tags.size()).map { i in
                CascTag(name: String(tags[i].first), value: tags[i].second)
            }
        }
        self.tags = rawTags
    }

    /// Load root entries once from C++ and cache them. All heavy work is done on background queue.
    /// Note: caller is responsible for setting/clearing `isLoading`.
    func loadInstallManifest() async -> (tags: [InstallManifestTag], entries: [InstallManifestEntry])? {
        guard !Task.isCancelled else { return nil }
        return await runOnQueue {
            let result = self.handle.parseInstallManifest()
            let tags = (0..<result.first.size()).map { i in
                InstallManifestTag(name: String(result.first[i].name), value: result.first[i].value)
            }
            let entries = (0..<result.second.size()).map { i in
                let entry = result.second[i]
                let bits = (0..<entry.tagBits.size()).map { entry.tagBits[$0] != 0 }
                return InstallManifestEntry(
                    fileName: String(entry.fileName),
                    ckey: String(entry.ckey),
                    fileSize: entry.fileSize,
                    tagBits: bits
                )
            }
            if tags.isEmpty && entries.isEmpty {
                return nil
            } else {
                return (tags: tags, entries: entries)
            }
        }
    }

    private func loadRootEntries() async {
        guard !Task.isCancelled else { return }
        loadProgressMessage = L("building_children_map")
        // Reset progress to 0 so the overlay shows an indeterminate spinner
        // instead of a stuck progress bar during this phase.
        loadProgress = 0
        var localHandle = handle
        let result: ([CASCFileEntry], [String: [DirectoryNode]], [String: CASCFileEntry], CascBridge.CascError) = await runOnQueue {
            var error = CascBridge.CascError.None
            let rawEntries = localHandle.listDirectory(std.string(""), &error)
            let mapped = (0..<rawEntries.size()).map { i in
                let entry = rawEntries[i]
                let swiftNameType: CascNameType
                switch entry.nameType {
                case .Full: swiftNameType = .full
                case .DataId: swiftNameType = .dataId
                case .CKey: swiftNameType = .ckey
                case .EKey: swiftNameType = .ekey
                default: swiftNameType = .full
                }
                return CASCFileEntry(
                    name: String(entry.name),
                    fullPath: String(entry.fullPath),
                    type: entry.type == .File ? .file : .directory,
                    size: entry.size,
                    encodingKey: String(entry.encodingKey),
                    isLocal: entry.isLocal,
                    nameType: swiftNameType,
                    tagBitMask: entry.tagBitMask
                )
            }
            
            let (childrenMap, entriesByPath) = Self.buildChildrenMap(from: mapped)
            
            return (mapped, childrenMap, entriesByPath, error)
        }
        
        loadProgressMessage = ""
        let (newEntries, childrenMap, newEntriesByPath, err) = result
        if err != .None {
            self.error = mapError(err)
        } else {
            self.allEntries = newEntries
            self.entriesByPath = newEntriesByPath
            self.childrenByPath = childrenMap
            self.currentPath = ""
            self.currentChildren = childrenMap[""] ?? []
            self.entries = []
            // Detect if entries lack human-readable names.
            // CascLib may report DataId/CKey placeholders as Full,
            // so we check filename patterns in addition to nameType.
            if !newEntries.isEmpty {
                let hasObfuscated = newEntries.contains { entry in
                    // CKey/EKey files go to virtual folders, not obfuscated
                    if entry.nameType == .ckey || entry.nameType == .ekey {
                        return false
                    }
                    let name = entry.name
                    // DataId placeholder: FILE00166360.dat
                    if name.count == 16, name.hasPrefix("FILE"), name.hasSuffix(".dat") {
                        let hexStart = name.index(name.startIndex, offsetBy: 4)
                        let hexEnd = name.index(name.startIndex, offsetBy: 12)
                        for ch in name[hexStart..<hexEnd] {
                            guard ch.isASCII && ch.isHexDigit else { return false }
                        }
                        return true
                    }
                    // CKey/EKey: 32 hex chars
                    if name.count == 32 {
                        for ch in name {
                            guard ch.isASCII && ch.isHexDigit else { return false }
                        }
                        return true
                    }
                    return false
                }
                // Once a listfile has been provided, don't prompt again even if some
                // files remain obfuscated (the listfile may be incomplete).
                self.needsListFile = hasObfuscated && self.listFilePath.isEmpty
            } else {
                self.needsListFile = false
            }
            
        }
    }

    /// Pre-compute a map from every directory path to its direct children.
    /// Also returns entriesByPath in the same pass to avoid a second iteration.
    /// Uses parallel chunks for large datasets.
    nonisolated static func buildChildrenMap(from entries: [CASCFileEntry]) -> (children: [String: [DirectoryNode]], entriesByPath: [String: CASCFileEntry]) {
        guard entries.count > 4096 else {
            return buildChildrenMapSerial(from: entries)
        }
        return buildChildrenMapParallel(from: entries)
    }

    /// Returns true for entries that have no human-readable path and should be
    /// grouped into the UNKNOWN virtual folder.
    /// Returns true for entries that have no human-readable path and should be
    /// grouped into the UNKNOWN virtual folder.
    /// Pass `normalizedPath` explicitly to avoid repeated string allocation.
    internal nonisolated static func isUncategorized(_ entry: CASCFileEntry, normalizedPath: String) -> Bool {
        if entry.nameType == .ckey || entry.nameType == .ekey {
            return false
        }
        // If it already has a directory path, keep it in the normal tree
        if normalizedPath.contains("/") {
            return false
        }
        let name = entry.name
        // DataId-style placeholder: FILE00166360.dat
        if name.count == 16, name.hasPrefix("FILE"), name.hasSuffix(".dat") {
            let hexStart = name.index(name.startIndex, offsetBy: 4)
            let hexEnd = name.index(name.startIndex, offsetBy: 12)
            for ch in name[hexStart..<hexEnd] {
                guard ch.isASCII && ch.isHexDigit else { return false }
            }
            return true
        }
        // CKey/EKey-style hex name
        if name.count == 32 {
            for ch in name {
                if !ch.isASCII || !ch.isHexDigit {
                    return false
                }
            }
            return true
        }
        return false
    }

    /// Backward-compatible overload that uses the pre-computed normalizedPath.
    internal nonisolated static func isUncategorized(_ entry: CASCFileEntry) -> Bool {
        return isUncategorized(entry, normalizedPath: entry.normalizedPath)
    }

    private nonisolated static func buildChildrenMapSerial(from entries: [CASCFileEntry]) -> (children: [String: [DirectoryNode]], entriesByPath: [String: CASCFileEntry]) {
        var fileNodesByPath: [String: [DirectoryNode]] = [:]
        var dirHasLocalFiles = Set<String>()
        var contentKeyFiles: [DirectoryNode] = []
        var encodedKeyFiles: [DirectoryNode] = []
        var uncategorizedFiles: [DirectoryNode] = []
        var entriesByPath: [String: CASCFileEntry] = [:]
        entriesByPath.reserveCapacity(entries.count)
        var parentPathsArray: [String] = []
        parentPathsArray.reserveCapacity(entries.count)
        var localParentPathsArray: [String] = []
        localParentPathsArray.reserveCapacity(entries.count / 4)

        for entry in entries {
            let normalized = entry.normalizedPath
            entriesByPath[normalized] = entry

            if entry.nameType == .ckey {
                contentKeyFiles.append(DirectoryNode(from: entry))
                continue
            }
            if entry.nameType == .ekey {
                encodedKeyFiles.append(DirectoryNode(from: entry))
                continue
            }
            if isUncategorized(entry, normalizedPath: normalized) {
                uncategorizedFiles.append(DirectoryNode(from: entry))
                continue
            }

            let parentPath: String
            if let idx = normalized.lastIndex(of: "/") {
                parentPath = String(normalized[..<idx])
            } else {
                parentPath = ""
            }

            fileNodesByPath[parentPath, default: []].append(
                DirectoryNode(name: entry.name, path: normalized, children: nil, isLocal: entry.isLocal, size: entry.size)
            )
            parentPathsArray.append(parentPath)
            if entry.isLocal {
                localParentPathsArray.append(parentPath)
            }
        }

        parentPathsArray.sort()
        var parentPaths: [String] = []
        parentPaths.reserveCapacity(parentPathsArray.count / 40)
        var lastPath = ""
        for path in parentPathsArray {
            if path != lastPath {
                parentPaths.append(path)
                lastPath = path
            }
        }

        localParentPathsArray.sort()
        var localParentPaths: [String] = []
        localParentPaths.reserveCapacity(localParentPathsArray.count / 40)
        lastPath = ""
        for path in localParentPathsArray {
            if path != lastPath {
                localParentPaths.append(path)
                lastPath = path
            }
        }

        // Build dirNamesByPath from unique parent paths only
        var dirNamesByPath: [String: Set<String>] = [:]
        for parentPath in parentPaths {
            guard !parentPath.isEmpty else { continue }
            let components = parentPath.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { continue }
            var currentPath = ""
            for i in 0..<(components.count - 1) {
                let dirName = String(components[i])
                dirNamesByPath[currentPath, default: Set()].insert(dirName)
                currentPath = currentPath.isEmpty ? dirName : currentPath + "/" + dirName
            }
            if let last = components.last {
                dirNamesByPath[currentPath, default: Set()].insert(String(last))
            }
        }

        // Build dirHasLocalFiles from local parent paths
        for parentPath in localParentPaths {
            guard !parentPath.isEmpty else { continue }
            let components = parentPath.split(separator: "/", omittingEmptySubsequences: true)
            var currentPath = ""
            for component in components {
                currentPath = currentPath.isEmpty ? String(component) : currentPath + "/" + String(component)
                dirHasLocalFiles.insert(currentPath)
            }
        }

        var map: [String: [DirectoryNode]] = [:]
        map.reserveCapacity(dirNamesByPath.count + 10)
        for (path, dirNames) in dirNamesByPath {
            var children: [DirectoryNode] = []
            children.reserveCapacity(dirNames.count)
            for dirName in dirNames {
                let dirPath = path.isEmpty ? dirName : path + "/" + dirName
                let isLocal = dirHasLocalFiles.contains(dirPath)
                let hasSubDirs = dirNamesByPath[dirPath]?.isEmpty == false
                children.append(DirectoryNode(name: dirName, path: dirPath, children: [], isLocal: isLocal, hasChildDirectories: hasSubDirs))
            }
            map[path] = children
        }

        for (path, files) in fileNodesByPath {
            let dirNameSet = dirNamesByPath[path] ?? []
            var children = map[path, default: []]
            children.reserveCapacity(children.count + files.count)
            for file in files {
                if !dirNameSet.contains(file.name) {
                    children.append(file)
                }
            }
            map[path] = children
        }

        // Sort every directory's children: directories first, then files, both A-Z
        for path in map.keys {
            map[path]?.sort {
                let aDir = $0.children != nil
                let bDir = $1.children != nil
                if aDir != bDir { return aDir && !bDir }
                return $0.name < $1.name
            }
        }

        var rootChildren = map[""] ?? []
        if !contentKeyFiles.isEmpty {
            rootChildren.append(DirectoryNode(name: "CONTENT_KEY", path: "CONTENT_KEY", children: [], isLocal: true))
            map["CONTENT_KEY"] = contentKeyFiles.sorted { $0.name < $1.name }
        }
        if !encodedKeyFiles.isEmpty {
            rootChildren.append(DirectoryNode(name: "ENCODED_KEY", path: "ENCODED_KEY", children: [], isLocal: true))
            map["ENCODED_KEY"] = encodedKeyFiles.sorted { $0.name < $1.name }
        }
        if !uncategorizedFiles.isEmpty {
            rootChildren.append(DirectoryNode(name: "UNKNOWN", path: "UNKNOWN", children: [], isLocal: true))
            map["UNKNOWN"] = uncategorizedFiles.sorted { $0.name < $1.name }
        }
        if !rootChildren.isEmpty {
            map[""] = rootChildren.sorted { $0.name < $1.name }
        }

        return (map, entriesByPath)
    }

    private nonisolated static func buildChildrenMapParallel(from entries: [CASCFileEntry]) -> (children: [String: [DirectoryNode]], entriesByPath: [String: CASCFileEntry]) {
        let processorCount = max(ProcessInfo.processInfo.processorCount, 1)
        let chunkSize = max(entries.count / processorCount, 4096)
        let chunkCount = (entries.count + chunkSize - 1) / chunkSize

        struct ChunkResult: Sendable {
            var parentPaths: [String] = []
            var localParentPaths: [String] = []
            var fileNodesByPath: [String: [DirectoryNode]] = [:]
            var contentKeyFiles: [DirectoryNode] = []
            var encodedKeyFiles: [DirectoryNode] = []
            var uncategorizedFiles: [DirectoryNode] = []
            var entriesByPath: [String: CASCFileEntry] = [:]
        }

        var chunkResults = [ChunkResult?](repeating: nil, count: chunkCount)
        let chunkLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, entries.count)
            var result = ChunkResult()
            result.entriesByPath.reserveCapacity(end - start)

            for i in start..<end {
                let entry = entries[i]
                let normalized = entry.normalizedPath
                result.entriesByPath[normalized] = entry

                if entry.nameType == .ckey {
                    result.contentKeyFiles.append(DirectoryNode(from: entry))
                    continue
                }
                if entry.nameType == .ekey {
                    result.encodedKeyFiles.append(DirectoryNode(from: entry))
                    continue
                }
                if isUncategorized(entry, normalizedPath: normalized) {
                    result.uncategorizedFiles.append(DirectoryNode(from: entry))
                    continue
                }

                let parentPath: String
                if let idx = normalized.lastIndex(of: "/") {
                    parentPath = String(normalized[..<idx])
                } else {
                    parentPath = ""
                }

                result.fileNodesByPath[parentPath, default: []].append(
                    DirectoryNode(name: entry.name, path: normalized, children: nil, isLocal: entry.isLocal, size: entry.size)
                )
                result.parentPaths.append(parentPath)
                if entry.isLocal {
                    result.localParentPaths.append(parentPath)
                }
            }

            chunkLock.lock()
            chunkResults[chunkIndex] = result
            chunkLock.unlock()
        }

        // Merge phase (serial)
        var parentPathsArray: [String] = []
        parentPathsArray.reserveCapacity(entries.count)
        var localParentPathsArray: [String] = []
        localParentPathsArray.reserveCapacity(entries.count / 4)
        var fileNodesByPath: [String: [DirectoryNode]] = [:]
        var contentKeyFiles: [DirectoryNode] = []
        var encodedKeyFiles: [DirectoryNode] = []
        var uncategorizedFiles: [DirectoryNode] = []
        var entriesByPath: [String: CASCFileEntry] = [:]
        entriesByPath.reserveCapacity(entries.count)

        for chunk in chunkResults.compactMap({ $0 }) {
            for (k, v) in chunk.entriesByPath {
                entriesByPath[k] = v
            }
            contentKeyFiles.append(contentsOf: chunk.contentKeyFiles)
            encodedKeyFiles.append(contentsOf: chunk.encodedKeyFiles)
            uncategorizedFiles.append(contentsOf: chunk.uncategorizedFiles)
            parentPathsArray.append(contentsOf: chunk.parentPaths)
            localParentPathsArray.append(contentsOf: chunk.localParentPaths)
            for (path, nodes) in chunk.fileNodesByPath {
                fileNodesByPath[path, default: []].append(contentsOf: nodes)
            }
        }

        let parentPaths = Set(parentPathsArray)
        let localParentPaths = Set(localParentPathsArray)

        // Build dirNamesByPath from unique parent paths only
        var dirNamesByPath: [String: Set<String>] = [:]
        for parentPath in parentPaths {
            guard !parentPath.isEmpty else { continue }
            let components = parentPath.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { continue }
            var currentPath = ""
            for i in 0..<(components.count - 1) {
                let dirName = String(components[i])
                dirNamesByPath[currentPath, default: Set()].insert(dirName)
                currentPath = currentPath.isEmpty ? dirName : currentPath + "/" + dirName
            }
            if let last = components.last {
                dirNamesByPath[currentPath, default: Set()].insert(String(last))
            }
        }

        // Build dirHasLocalFiles from local parent paths
        var dirHasLocalFiles = Set<String>()
        for parentPath in localParentPaths {
            guard !parentPath.isEmpty else { continue }
            let components = parentPath.split(separator: "/", omittingEmptySubsequences: true)
            var currentPath = ""
            for component in components {
                currentPath = currentPath.isEmpty ? String(component) : currentPath + "/" + String(component)
                dirHasLocalFiles.insert(currentPath)
            }
        }

        var map: [String: [DirectoryNode]] = [:]
        map.reserveCapacity(dirNamesByPath.count + 10)
        for (path, dirNames) in dirNamesByPath {
            var children: [DirectoryNode] = []
            children.reserveCapacity(dirNames.count)
            for dirName in dirNames {
                let dirPath = path.isEmpty ? dirName : path + "/" + dirName
                let isLocal = dirHasLocalFiles.contains(dirPath)
                let hasSubDirs = dirNamesByPath[dirPath]?.isEmpty == false
                children.append(DirectoryNode(name: dirName, path: dirPath, children: [], isLocal: isLocal, hasChildDirectories: hasSubDirs))
            }
            map[path] = children
        }

        for (path, files) in fileNodesByPath {
            let pathStr = String(path)
            let dirNameSet = dirNamesByPath[pathStr] ?? []
            var children = map[pathStr, default: []]
            children.reserveCapacity(children.count + files.count)
            for file in files {
                if !dirNameSet.contains(file.name) {
                    children.append(file)
                }
            }
            map[pathStr] = children
        }

        // Sort every directory's children: directories first, then files, both A-Z
        for path in map.keys {
            map[path]?.sort {
                let aDir = $0.children != nil
                let bDir = $1.children != nil
                if aDir != bDir { return aDir && !bDir }
                return $0.name < $1.name
            }
        }

        var rootChildren = map[""] ?? []
        if !contentKeyFiles.isEmpty {
            rootChildren.append(DirectoryNode(name: "CONTENT_KEY", path: "CONTENT_KEY", children: [], isLocal: true))
            map["CONTENT_KEY"] = contentKeyFiles.sorted { $0.name < $1.name }
        }
        if !encodedKeyFiles.isEmpty {
            rootChildren.append(DirectoryNode(name: "ENCODED_KEY", path: "ENCODED_KEY", children: [], isLocal: true))
            map["ENCODED_KEY"] = encodedKeyFiles.sorted { $0.name < $1.name }
        }
        if !uncategorizedFiles.isEmpty {
            rootChildren.append(DirectoryNode(name: "UNKNOWN", path: "UNKNOWN", children: [], isLocal: true))
            map["UNKNOWN"] = uncategorizedFiles.sorted { $0.name < $1.name }
        }
        if !rootChildren.isEmpty {
            map[""] = rootChildren.sorted { $0.name < $1.name }
        }

        return (map, entriesByPath)
    }

    /// Pure in-memory navigation — O(1) lookup via pre-computed map.
    func navigate(to path: String) {
        guard self.currentPath != path else { return }
        self.currentPath = path
        self.currentChildren = childrenByPath[path, default: []]
    }

    /// Rebuild the children map and reload current directory view.
    func refreshCurrentStorage() async {
        guard !isLoading else { return }
        isLoading = true
        loadProgress = 0
        loadProgressMessage = L("loading_listfile")
        await loadRootEntries()
        await loadTags()
        self.currentChildren = childrenByPath[currentPath, default: []]
        isLoading = false
        loadProgressMessage = ""
    }

    /// Maximum allowed regex pattern length to prevent ReDoS via overly complex patterns.
    private nonisolated static let maxRegexPatternLength = 256

    /// Pre-compiled ReDoS detection regex to avoid recompilation on every call.
    private nonisolated static let dangerousRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\([^)]*[*+?][^)]*\)[*+?]"#, options: [])
    }()

    /// Reject patterns with nested quantifiers that are common ReDoS vectors:
    /// e.g. (a+)+, (a*)*, (a+)*, (a*)+, ((a+)?)+, etc.
    nonisolated static func isSafeRegexPattern(_ pattern: String) -> Bool {
        // Limit pattern length
        if pattern.count > maxRegexPatternLength { return false }
        // Reject patterns containing nested repetition groups (heuristic)
        let range = NSRange(pattern.startIndex..., in: pattern)
        if let dangerous = dangerousRegex, dangerous.firstMatch(in: pattern, options: [], range: range) != nil {
            return false
        }
        return true
    }

    func entry(forPath path: String) -> CASCFileEntry? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        // Virtual directories are not real file entries
        if normalized == "CONTENT_KEY" || normalized == "ENCODED_KEY" {
            return nil
        }
        return entriesByPath[normalized]
    }

    /// Return all file entries under a given directory path (recursive).
    func entriesUnder(path: String) -> [CASCFileEntry] {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized == "CONTENT_KEY" {
            return allEntries.filter { $0.nameType == .ckey }
        }
        if normalized == "ENCODED_KEY" {
            return allEntries.filter { $0.nameType == .ekey }
        }
        if normalized == "UNKNOWN" {
            return allEntries.filter { Self.isUncategorized($0) }
        }
        // Use childrenByPath BFS to avoid O(n) linear scan over allEntries
        if let children = childrenByPath[normalized] {
            var result: [CASCFileEntry] = []
            var queue = children
            var index = 0
            while index < queue.count {
                let node = queue[index]
                index += 1
                if node.children != nil {
                    if let subChildren = childrenByPath[node.path] {
                        queue.append(contentsOf: subChildren)
                    }
                } else if let entry = entriesByPath[node.path] {
                    result.append(entry)
                }
            }
            return result
        }
        let prefix = normalized.isEmpty ? "" : normalized + "/"
        return allEntries.filter { $0.normalizedPath.hasPrefix(prefix) }
    }

    func readFileData(forPath path: String) async -> Data? {
        guard !Task.isCancelled else { return nil }
        var localHandle = handle
        return await runOnQueue {
            var error = CascBridge.CascError.None
            let result = localHandle.readFile(std.string(path), &error)
            guard error == .None else {
                return nil
            }
            return Data(result)
        }
    }

    func close() {
        handle.close()
        entries = []
        allEntries = []
        currentChildren = []
        currentPath = ""
        storageInfo = nil
        entriesByPath = [:]

        childrenByPath = [:]
        tags = []
        error = nil
        loadProgress = 0
        loadProgressMessage = ""
    }

    private func refreshStorageInfo() async {
        guard !Task.isCancelled else { return }
        var localHandle = handle
        let (info, err) = await runOnQueue {
            var error = CascBridge.CascError.None
            let info = localHandle.getStorageInfo(&error)
            return (info, error)
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
        case .NotImplemented: return .notImplemented
        case .Cancelled: return .cancelled
        case .None, .Unknown: return .unknown
        @unknown default: return .unknown
        }
    }
}
