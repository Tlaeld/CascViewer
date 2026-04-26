import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState
    @State private var directories: [String] = []

    var body: some View {
        List {
            if let storage = appState.currentStorage, !storage.entries.isEmpty {
                ForEach(directories, id: \.self) { dir in
                    Label(dir.isEmpty ? "(root)" : dir, systemImage: "folder")
                        .onTapGesture {
                            Task {
                                await storage.listDirectory(path: dir)
                            }
                        }
                }
            } else {
                Text("Open a storage to browse")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            if let entries = appState.currentStorage?.entries {
                directories = Self.extractDirectories(from: entries).sorted()
            }
        }
        .onChange(of: appState.currentStorage?.entries) { _ in
            guard let entries = appState.currentStorage?.entries else {
                directories = []
                return
            }
            Task.detached(priority: .userInitiated) {
                let result = Self.extractDirectories(from: entries)
                await MainActor.run {
                    directories = result.sorted()
                }
            }
        }
    }

    private nonisolated static func extractDirectories(from entries: [CASCFileEntry]) -> Set<String> {
        var dirs = Set<String>()
        for entry in entries {
            let path = entry.fullPath
            if let lastSlash = path.lastIndex(of: "/") {
                let dir = String(path[..<lastSlash])
                dirs.insert(dir)
            } else {
                dirs.insert("")
            }
        }
        return dirs
    }
}
