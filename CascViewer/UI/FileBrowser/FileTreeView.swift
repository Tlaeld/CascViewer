import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState
    @State private var topLevelDirs: [String] = []

    var body: some View {
        List {
            if let storage = appState.currentStorage, !storage.allEntries.isEmpty {
                Section("Directories") {
                    ForEach(topLevelDirs, id: \.self) { dir in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                                .font(.system(size: 12))
                            Text(dir)
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task {
                                await storage.listDirectory(path: dir)
                            }
                        }
                    }
                }
            } else {
                Text("Open a storage to browse")
                    .foregroundColor(.secondary)
                    .font(.callout)
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            if let entries = appState.currentStorage?.allEntries {
                topLevelDirs = Self.topLevelDirs(from: entries)
            }
        }
        .onChange(of: appState.currentStorage?.allEntries) { _ in
            if let entries = appState.currentStorage?.allEntries {
                topLevelDirs = Self.topLevelDirs(from: entries)
            } else {
                topLevelDirs = []
            }
        }
    }

    private nonisolated static func topLevelDirs(from entries: [CASCFileEntry]) -> [String] {
        var dirs = Set<String>()
        for entry in entries {
            let components = entry.fullPath.split(separator: "/", omittingEmptySubsequences: true)
            if let first = components.first {
                dirs.insert(String(first))
            }
        }
        return dirs.sorted()
    }
}
