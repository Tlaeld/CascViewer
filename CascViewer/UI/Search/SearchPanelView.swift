import SwiftUI

struct SearchPanelView: View {
    @EnvironmentObject var appState: AppState
    var initialQuery: String = ""

    @State private var query = ""
    @State private var searchScope: SearchScope = .entireStorage
    @State private var useRegex = false
    @State private var caseSensitive = false
    @State private var selectedTypes = Set<String>()
    @State private var customExtension = ""
    @State private var results: [CASCFileEntry] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var hasAutoSearched = false
    @State private var sortBy: SortBy = .name
    @State private var sortAscending = true

    let builtInTypes = ["BLP", "MDX", "MP3", "WAV", "TXT", "DBC", "M2", "OGG", "TGA", "PNG", "JPG"]

    enum SearchScope: CaseIterable {
        case entireStorage
        case currentDirectory
    }

    enum SortBy: CaseIterable {
        case name
        case size
        case path
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top search bar
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))

                    TextField(L("search_query_placeholder"), text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { performSearch() }

                    if isSearching {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }

                    if !query.isEmpty && !isSearching {
                        Button(action: { query = "" }) {
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

                Picker("", selection: $searchScope) {
                    Text(L("search_scope_entire")).tag(SearchScope.entireStorage)
                    Text(L("search_scope_current")).tag(SearchScope.currentDirectory)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                Button(isSearching ? L("cancel") : L("search")) {
                    if isSearching {
                        searchTask?.cancel()
                        isSearching = false
                    } else {
                        performSearch()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isSearching && query.isEmpty)
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

                        Toggle(L("search_use_regex"), isOn: $useRegex)
                        Toggle(L("search_case_sensitive"), isOn: $caseSensitive)
                    }

                    Divider()

                    Group {
                        Text(L("search_file_type"))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 6) {
                            ForEach(builtInTypes, id: \.self) { type in
                                TypeChip(
                                    type: type,
                                    isSelected: selectedTypes.contains(type)
                                ) {
                                    toggleType(type)
                                }
                            }
                        }

                        HStack {
                            Text(L("search_custom_ext"))
                                .font(.caption)
                            TextField(L("search_custom_ext_placeholder"), text: $customExtension)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .onSubmit { performSearch() }
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
                        if isSearching {
                            Text(L("search_searching"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if !query.isEmpty {
                            Text(L("search_result_count", results.count))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if !results.isEmpty {
                            Picker(L("search_sort_by"), selection: $sortBy) {
                                Text(L("search_sort_name")).tag(SortBy.name)
                                Text(L("search_sort_size")).tag(SortBy.size)
                                Text(L("search_sort_path")).tag(SortBy.path)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)

                            Button(action: { sortAscending.toggle() }) {
                                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
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
                    if results.isEmpty && !isSearching && !query.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text(L("search_no_results"))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if query.isEmpty && !isSearching {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text(L("search_empty_prompt"))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(sortedResults) { entry in
                            SearchResultRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    navigateToEntry(entry)
                                }
                                .contextMenu {
                                    Button(L("search_go_to_location")) {
                                        navigateToEntry(entry)
                                    }
                                    Button(L("copy_path")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(entry.fullPath.replacingOccurrences(of: "\\", with: "/"), forType: .string)
                                    }
                                }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onAppear {
            if !hasAutoSearched {
                query = initialQuery
                hasAutoSearched = true
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private var sortedResults: [CASCFileEntry] {
        let sorted: [CASCFileEntry]
        switch sortBy {
        case .name:
            sorted = results.sorted { sortAscending ? $0.name < $1.name : $0.name > $1.name }
        case .size:
            sorted = results.sorted { sortAscending ? $0.size < $1.size : $0.size > $1.size }
        case .path:
            sorted = results.sorted { sortAscending ? $0.fullPath < $1.fullPath : $0.fullPath > $1.fullPath }
        }
        return sorted
    }

    private func toggleType(_ type: String) {
        if selectedTypes.contains(type) {
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
        if !results.isEmpty && !query.isEmpty {
            performSearch()
        }
    }

    private func performSearch() {
        guard let storage = appState.currentStorage else { return }
        searchTask?.cancel()
        isSearching = true
        results = []

        let path = searchScope == .currentDirectory ? storage.currentPath : ""

        searchTask = Task {
            do {
                let searchService = CASCSearchService(storage: storage)
                var searchResults = await searchService.search(query: query, in: path, useRegex: useRegex)

                guard !Task.isCancelled else { return }

                // Apply type filters
                let allTypes = selectedTypes.union(parseCustomExtensions())
                if !allTypes.isEmpty {
                    searchResults = searchResults.filter { entry in
                        let ext = (entry.name as NSString).pathExtension.uppercased()
                        return allTypes.contains(ext)
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    results = searchResults
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    appState.errorMessage = L("search_failed", error.localizedDescription)
                }
            }
        }
    }

    private func parseCustomExtensions() -> Set<String> {
        customExtension
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func navigateToEntry(_ entry: CASCFileEntry) {
        let parentPath: String
        if entry.nameType == .ckey {
            parentPath = "CONTENT_KEY"
        } else if entry.nameType == .ekey {
            parentPath = "ENCODED_KEY"
        } else {
            parentPath = (entry.fullPath as NSString).deletingLastPathComponent
        }
        appState.currentStorage?.navigate(to: parentPath)
        appState.selectedPath = entry.fullPath
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

// MARK: - Search Result Row

struct SearchResultRow: View {
    let entry: CASCFileEntry

    var displayPath: String {
        entry.fullPath.replacingOccurrences(of: "\\", with: "/")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                Text(displayPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}
