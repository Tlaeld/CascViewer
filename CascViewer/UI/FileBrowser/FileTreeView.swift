import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var appState: AppState
    @State private var treeRoots: [TreeNode] = []

    var body: some View {
        List {
            if let storage = appState.currentStorage, !storage.allEntries.isEmpty {
                OutlineGroup(treeRoots, children: \.children) { node in
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 12))
                        Text(node.name)
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            await storage.listDirectory(path: node.path)
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
                treeRoots = Self.buildTree(from: entries)
            }
        }
        .onChange(of: appState.currentStorage?.allEntries) { _ in
            guard let entries = appState.currentStorage?.allEntries else {
                treeRoots = []
                return
            }
            Task.detached(priority: .userInitiated) {
                let result = Self.buildTree(from: entries)
                await MainActor.run {
                    treeRoots = result
                }
            }
        }
    }

    // MARK: - Tree Model

    struct TreeNode: Identifiable {
        let id: String
        let name: String
        let path: String
        var children: [TreeNode]?
    }

    // MARK: - Tree Building

    private nonisolated static func buildTree(from entries: [CASCFileEntry]) -> [TreeNode] {
        var dirSet = Set<String>()

        for entry in entries {
            let path = entry.fullPath
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            // All prefixes except the last component (filename) are directories
            var current = ""
            for i in 0..<(components.count - 1) {
                current = current.isEmpty ? String(components[i]) : current + "/" + String(components[i])
                dirSet.insert(current)
            }
        }

        // Build parent -> child names map
        var childrenMap: [String: Set<String>] = [:]
        for dir in dirSet {
            let components = dir.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { continue }
            let parent = components.dropLast().joined(separator: "/")
            let name = String(components.last!)
            childrenMap[parent, default: []].insert(name)
        }

        func buildNodes(for path: String) -> [TreeNode] {
            let childNames = childrenMap[path, default: []].sorted()
            return childNames.map { name in
                let childPath = path.isEmpty ? name : path + "/" + name
                let childNodes = buildNodes(for: childPath)
                return TreeNode(
                    id: childPath,
                    name: name,
                    path: childPath,
                    children: childNodes.isEmpty ? nil : childNodes
                )
            }
        }

        return buildNodes(for: "")
    }
}
