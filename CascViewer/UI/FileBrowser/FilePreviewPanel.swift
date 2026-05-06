import SwiftUI

struct FilePreviewPanel: View {
    @EnvironmentObject var appState: AppState

    private var selectedEntry: CASCFileEntry? {
        guard let storage = appState.currentStorage, !appState.selectedPath.isEmpty else { return nil }
        return storage.entry(forPath: appState.selectedPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("details_panel"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            .font(.system(size: 28))
                            .foregroundColor(entry.isDirectory ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(entry.isDirectory ? "Folder" : "File")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    Divider()

                    InfoRow(label: "Path", value: entry.fullPath)
                    InfoRow(label: "Size", value: entry.formattedSize)
                    InfoRow(label: "Encoding Key", value: entry.encodingKey)

                    if entry.name.lowercased().hasSuffix(".blp") {
                        Button("Open BLP Viewer") {
                            // Open BLP viewer window — Task 14
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .padding(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select a file to see details")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }

            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
