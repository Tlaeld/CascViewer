import SwiftUI
import CascBridge

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

                    InfoRow(label: "Path", value: entry.normalizedPath)
                    InfoRow(label: "Size", value: entry.formattedSize)
                    InfoRow(label: "Encoding Key", value: entry.encodingKey)

                    if isImageFile(entry.name) {
                        Button("Open Image Viewer") {
                            Task {
                                await openImageFile(entry: entry)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select a file to see details")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func isImageFile(_ name: String) -> Bool {
        let ext = name.lowercased()
        return ext.hasSuffix(".blp") || ext.hasSuffix(".dds")
    }

    private func openImageFile(entry: CASCFileEntry) async {
        guard let storageService = appState.currentStorage else { return }

        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CascViewer/Open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let safeName = entry.name
            .components(separatedBy: "/")
            .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
            .joined(separator: "_")
        let destURL = sessionDir.appendingPathComponent(safeName)

        let extractService = CASCExtractService(storage: storageService.handle)
        let result = await extractService.extract(entries: [entry], to: sessionDir, preserveStructure: false)

        if result.failedFiles.isEmpty, let data = try? Data(contentsOf: destURL) {
            openImageViewerWindow(fileName: safeName, imageData: data)
        }
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
