import SwiftUI

struct SearchPanelView: View {
    @ObservedObject var appState: AppState
    @StateObject private var settings = AppSettings.shared

    @State private var searchTask: Task<Void, Never>? = nil
    @State private var selectedMatchId: String? = nil
    @State private var sortedMatches: [SearchMatch] = []
    @State private var sortTask: Task<Void, Never>? = nil
    @State private var showingExtractSheet = false
    @State private var extractEntries: [CASCFileEntry] = []
    @State private var activeExtractService: CASCExtractService? = nil

    let builtInTypes = ["BLP", "DDS", "MDX", "MP3", "WAV", "TXT", "DBC", "M2", "OGG", "TGA", "PNG", "JPG", "JSON", "XML", "LUA"]

    var body: some View {
        VStack(spacing: 0) {
            // Top search bar
            HStack(spacing: 8) {
                // Mode picker: only filename/content/hex
                Picker("", selection: $appState.searchMode) {
                    Text(SearchMode.filename.displayName).tag(SearchMode.filename)
                    Text(SearchMode.content.displayName).tag(SearchMode.content)
                    Text(SearchMode.hex.displayName).tag(SearchMode.hex)
                    Text(SearchMode.tag.displayName).tag(SearchMode.tag)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: appState.searchMode) { _ in
                    searchTask?.cancel()
                    appState.searchIsSearching = false
                    appState.searchResults = []
                    sortedMatches = []
                }

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))

                    TextField(appState.searchMode.placeholder, text: $appState.searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { performSearch() }

                    if appState.searchIsSearching {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }

                    if !appState.searchQuery.isEmpty && !appState.searchIsSearching {
                        Button(action: { appState.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Picker("", selection: $appState.searchScope) {
                    Text(L("search_scope_entire")).tag(SearchScope.entireStorage)
                    Text(L("search_scope_current")).tag(SearchScope.currentDirectory)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Spacer()

                Button(appState.searchIsSearching ? L("cancel") : L("search")) {
                    if appState.searchIsSearching {
                        searchTask?.cancel()
                        appState.searchIsSearching = false
                    } else {
                        performSearch()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.searchIsSearching && !canSearch)
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // Two-column layout
            HStack(spacing: 0) {
                // Left: Filters
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        Text(L("search_match_options"))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle(L("search_use_regex"), isOn: $appState.searchUseRegex)
                        Toggle(L("search_case_sensitive"), isOn: $appState.searchCaseSensitive)
                        Toggle(L("search_include_path"), isOn: $appState.searchIncludePath)
                    }

                    Divider()

                    // File types
                    Group {
                        Text(L("search_file_type"))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 6) {
                            ForEach(builtInTypes, id: \.self) { type in
                                TypeChip(
                                    type: type,
                                    isSelected: appState.searchSelectedTypes.contains(type)
                                ) {
                                    toggleType(type)
                                }
                            }
                        }

                        HStack {
                            Text(L("search_custom_ext"))
                                .font(.caption)
                            TextField(L("search_custom_ext_placeholder"), text: $appState.searchCustomExtension)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .onSubmit { performSearch() }
                        }
                    }

                    Divider()

                    // Tags (only relevant in tag search mode)
                    if appState.searchMode == .tag {
                        Group {
                            Text(L("search_tags"))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            let tags = appState.currentStorage?.tags ?? []
                            if tags.isEmpty {
                                Text(L("search_no_tags"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
                                LazyVGrid(columns: columns, spacing: 6) {
                                    ForEach(tags, id: \.name) { tag in
                                        TagCheckbox(
                                            label: tag.name,
                                            isSelected: appState.searchSelectedTags.contains(tag.name)
                                        ) {
                                            if appState.searchSelectedTags.contains(tag.name) {
                                                appState.searchSelectedTags.remove(tag.name)
                                            } else {
                                                appState.searchSelectedTags.insert(tag.name)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Spacer()
                }
                .padding()
                .frame(width: 300)

                Divider()

                // Right: Results
                VStack(spacing: 0) {
                    // Results header
                    HStack {
                        if appState.searchIsSearching {
                            Text(L("search_searching"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if !appState.searchQuery.isEmpty {
                            Text(L("search_result_count", appState.searchResults.count))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if !appState.searchResults.isEmpty {
                            Picker(L("search_sort_by"), selection: $appState.searchSortBy) {
                                Text(L("search_sort_name")).tag(SearchSortBy.name)
                                Text(L("search_sort_size")).tag(SearchSortBy.size)
                                Text(L("search_sort_path")).tag(SearchSortBy.path)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)

                            Button(action: { appState.searchSortAscending.toggle() }) {
                                Image(systemName: appState.searchSortAscending ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))

                    Divider()

                    // Results list
                    if appState.searchResults.isEmpty && !appState.searchIsSearching && !appState.searchQuery.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text(L("search_no_results"))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if appState.searchQuery.isEmpty && !appState.searchIsSearching {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text(L("search_empty_prompt"))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SearchResultTableView(
                            matches: sortedMatches,
                            searchMode: appState.searchMode,
                            selectedMatchId: selectedMatchId,
                            onSelect: { match in
                                selectedMatchId = match.id
                            },
                            onDoubleClick: { match in
                                navigateToEntry(match.entry)
                            },
                            onCopyPath: { path in
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                            },
                            onOpenFile: { match in
                                navigateToEntry(match.entry)
                            },
                            onExtract: { match in
                                extractEntries = [match.entry]
                                showingExtractSheet = true
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: appState.searchResults) { _ in applySorting() }
        .onChange(of: appState.searchSortBy) { _ in applySorting() }
        .onChange(of: appState.searchSortAscending) { _ in applySorting() }
        .onAppear {
            applySorting()
        }
        .onDisappear {
            searchTask?.cancel()
            appState.searchIsSearching = false
        }
        .onChange(of: appState.currentStorage?.allEntriesCount) { _ in
            searchTask?.cancel()
            appState.searchIsSearching = false
            appState.searchResults = []
            sortedMatches = []
        }
        .sheet(isPresented: $showingExtractSheet) {
            if appState.currentStorage != nil {
                ExtractDialogView(entries: extractEntries) { destination, preserveStructure, overwriteExisting, openAfterExtract in
                    Task {
                        await performExtraction(to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting, openAfterExtract: openAfterExtract)
                    }
                }
            }
        }
        .overlay {
            if let service = activeExtractService, service.isExtracting {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text(L("downloading_file", service.currentFile))
                            .font(.system(size: 14, weight: .semibold))
                        ProgressView(value: service.progress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)
                        Text("\(Int(service.progress * 100))%")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        Button(L("cancel")) {
                            activeExtractService?.cancel()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 8)
                }
            }
        }
        .id(settings.language)
    }

    private var canSearch: Bool {
        if appState.searchMode == .tag {
            return !appState.searchSelectedTags.isEmpty
        }
        return !appState.searchQuery.isEmpty
    }

    private func applySorting() {
        sortTask?.cancel()
        let results = appState.searchResults
        let sortBy = appState.searchSortBy
        let ascending = appState.searchSortAscending
        sortTask = Task {
            let sorted = await Task.detached(priority: .userInitiated) {
                let sorted: [SearchMatch]
                switch sortBy {
                case .name:
                    sorted = results.sorted { ascending ? $0.entry.name < $1.entry.name : $0.entry.name > $1.entry.name }
                case .size:
                    sorted = results.sorted { ascending ? $0.entry.size < $1.entry.size : $0.entry.size > $1.entry.size }
                case .path:
                    sorted = results.sorted { ascending ? $0.entry.fullPath < $1.entry.fullPath : $0.entry.fullPath > $1.entry.fullPath }
                }
                return sorted
            }.value
            guard !Task.isCancelled else { return }
            self.sortedMatches = sorted
        }
    }

    private func toggleType(_ type: String) {
        if appState.searchSelectedTypes.contains(type) {
            appState.searchSelectedTypes.remove(type)
        } else {
            appState.searchSelectedTypes.insert(type)
        }
        if !appState.searchResults.isEmpty && !appState.searchQuery.isEmpty {
            performSearch()
        }
    }

    private func performSearch() {
        guard let storage = appState.currentStorage else { return }
        searchTask?.cancel()
        appState.searchIsSearching = true
        appState.searchResults = []

        let request = SearchRequest(
            mode: appState.searchMode,
            query: appState.searchQuery,
            scope: appState.searchScope,
            caseSensitive: appState.searchCaseSensitive,
            useRegex: appState.searchUseRegex,
            includePath: appState.searchIncludePath,
            fileTypes: appState.searchSelectedTypes.union(parseCustomExtensions()),
            selectedTags: appState.searchSelectedTags,
            availableTags: storage.tags
        )

        searchTask = Task {
            let searchService = CASCSearchService(handle: storage.handle)
            let searchResults = await searchService.search(
                request,
                allEntries: storage.allEntries,
                entries: storage.entries,
                currentPath: storage.currentPath
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                appState.searchResults = searchResults
                appState.searchIsSearching = false
                // applySorting() is triggered by .onChange(of: appState.searchResults)
            }
        }
    }

    private func parseCustomExtensions() -> Set<String> {
        appState.searchCustomExtension
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func performExtraction(to destination: URL, preserveStructure: Bool, overwriteExisting: Bool, openAfterExtract: Bool) async {
        guard let storageService = appState.currentStorage else { return }
        let extractService = CASCExtractService(storage: storageService.handle)
        await MainActor.run {
            activeExtractService = extractService
        }
        let result = await extractService.extract(entries: extractEntries, to: destination, preserveStructure: preserveStructure, overwriteExisting: overwriteExisting)
        await MainActor.run {
            activeExtractService = nil
        }
        if result.failedFiles.isEmpty {
            appState.errorMessage = L("extract_success", result.successCount)
            if openAfterExtract {
                _ = await MainActor.run {
                    NSWorkspace.shared.open(destination)
                }
            }
        } else {
            let failedList = result.failedFiles.prefix(10).map {
                let reason = $0.error.localizedDescription
                return "\($0.path)\n  ↳ \(reason)"
            }.joined(separator: "\n")
            let more = result.failedFiles.count > 10 ? "\n... \(result.failedFiles.count - 10) more" : ""
            appState.errorMessage = L("extract_partial", result.successCount, result.failedFiles.count) + "\n\n" + failedList + more
        }
    }

    private func navigateToEntry(_ entry: CASCFileEntry) {
        let parentPath: String
        if entry.nameType == .ckey {
            parentPath = "CONTENT_KEY"
        } else if entry.nameType == .ekey {
            parentPath = "ENCODED_KEY"
        } else {
            let normalized = entry.normalizedPath
            parentPath = (normalized as NSString).deletingLastPathComponent
        }
        appState.currentStorage?.navigate(to: parentPath)
        appState.selectedPath = entry.fullPath

        // Bring main window to front while keeping search window open
        if let mainWindow = NSApp.windows.first(where: { $0 != SearchWindowController.shared?.window && $0.isVisible }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Type Chip

struct TypeChip: View {
    let type: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(type)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tag Checkbox

struct TagCheckbox: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 12))
                    .frame(width: 16, alignment: .leading)
                Text(label)
                    .font(.caption)
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}


