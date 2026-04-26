import SwiftUI

struct SearchPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var useRegex = false
    @State private var selectedTypes = Set<String>()
    @State private var results: [CASCFileEntry] = []
    @State private var isSearching = false

    let fileTypes = ["BLP", "MDX", "MP3", "WAV", "TXT", "DBC"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search...", text: $query)
                    .textFieldStyle(.roundedBorder)

                Toggle("Regex", isOn: $useRegex)

                Button("Search") {
                    performSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(query.isEmpty)
            }
            .padding()

            Divider()

            List {
                Section("Filter by Type") {
                    ForEach(fileTypes, id: \.self) { type in
                        Toggle(type, isOn: Binding(
                            get: { selectedTypes.contains(type) },
                            set: { isOn in
                                if isOn {
                                    selectedTypes.insert(type)
                                } else {
                                    selectedTypes.remove(type)
                                }
                            }
                        ))
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(height: 200)

            Divider()

            if isSearching {
                ProgressView("Searching...")
                    .padding()
            }

            List(results) { entry in
                HStack {
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        Text(entry.fullPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    private func performSearch() {
        guard let storage = appState.currentStorage else { return }
        isSearching = true
        results = []

        Task {
            let searchService = CASCSearchService(storage: storage)
            var searchResults = await searchService.search(query: query, in: storage.currentPath, useRegex: useRegex)

            if !selectedTypes.isEmpty {
                searchResults = searchResults.filter { entry in
                    let ext = (entry.name as NSString).pathExtension.uppercased()
                    return selectedTypes.contains(ext)
                }
            }

            await MainActor.run {
                results = searchResults
                isSearching = false
            }
        }
    }
}
