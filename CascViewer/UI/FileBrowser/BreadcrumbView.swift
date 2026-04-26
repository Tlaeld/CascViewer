import SwiftUI

struct BreadcrumbView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            if let storage = appState.currentStorage {
                Button {
                    Task { await storage.listDirectory(path: "") }
                } label: {
                    Image(systemName: "house")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                let components = pathComponents(for: storage.currentPath)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    Text("›")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 2)

                    Button {
                        let path = components[0...index].joined(separator: "/")
                        Task { await storage.listDirectory(path: path) }
                    } label: {
                        Text(component)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func pathComponents(for path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        return path.split(separator: "/").map(String.init)
    }
}
