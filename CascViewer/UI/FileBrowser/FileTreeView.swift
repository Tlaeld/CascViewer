import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if let storage = appState.currentStorage {
                if !storage.entries.isEmpty || storage.currentPath.isEmpty {
                    Section("Directories") {
                        ForEach(directories(from: storage.entries), id: \.self) { dir in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 12))
                                Text(dir.isEmpty ? "(root)" : dir)
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
                    Text("No entries")
                        .foregroundColor(.secondary)
                        .font(.callout)
                }
            } else {
                Text("Open a storage to browse")
                    .foregroundColor(.secondary)
                    .font(.callout)
            }
        }
        .listStyle(.sidebar)
    }

    private func directories(from entries: [CASCFileEntry]) -> [String] {
        var dirs = Set<String>()
        for entry in entries {
            let path = entry.fullPath
            let nsPath = path as NSString
            let separators = CharacterSet(charactersIn: "/\\")
            let lastSep = nsPath.rangeOfCharacter(from: separators, options: .backwards)
            if lastSep.location != NSNotFound {
                let dir = nsPath.substring(to: lastSep.location)
                dirs.insert(dir)
            } else {
                dirs.insert("")
            }
        }
        return Array(dirs).sorted()
    }
}
