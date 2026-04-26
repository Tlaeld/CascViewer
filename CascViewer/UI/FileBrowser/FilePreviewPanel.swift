import SwiftUI

struct FilePreviewPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)
                .padding(.horizontal)

            Divider()

            if let storage = appState.currentStorage,
               let entry = storage.entries.first(where: { $0.fullPath == appState.selectedPath }) {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Name", value: entry.name)
                    InfoRow(label: "Path", value: entry.fullPath)
                    InfoRow(label: "Size", value: entry.formattedSize)
                    InfoRow(label: "Type", value: entry.isDirectory ? "Directory" : "File")

                    if entry.name.lowercased().hasSuffix(".blp") {
                        Button("Open BLP Viewer") {
                            // Open BLP viewer window — Task 14
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal)
            } else {
                Text("Select a file to see details")
                    .foregroundColor(.secondary)
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
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
    }
}
