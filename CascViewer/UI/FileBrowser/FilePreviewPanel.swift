import SwiftUI
import AppKit
import CascBridge

struct FilePreviewPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedEntry: CASCFileEntry? = nil
    @State private var isOpeningImage = false
    @State private var openFileTask: Task<Void, Never>? = nil

    private func refreshSelectedEntry() {
        guard let storage = appState.currentStorage, !appState.selectedPath.isEmpty else {
            selectedEntry = nil
            return
        }
        selectedEntry = storage.entry(forPath: appState.selectedPath)
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
                            Text(entry.isDirectory ? L("folder") : L("file"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    Divider()

                    InfoRow(label: L("path_label"), value: entry.normalizedPath)
                    InfoRow(label: L("size_label"), value: entry.formattedSize)
                    InfoRow(label: L("encoding_key_label"), value: entry.encodingKey)

                    if isImageFile(entry.name) {
                        Button(action: {
                            isOpeningImage = true
                            openFileTask = Task {
                                await openImageFile(entry: entry)
                                isOpeningImage = false
                            }
                        }) {
                            if isOpeningImage {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            } else {
                                Text(L("open_image_viewer"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                        .disabled(isOpeningImage)
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
                    Text(L("select_file_for_details"))
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
        .onAppear {
            refreshSelectedEntry()
        }
        .onChange(of: appState.selectedPath) { _ in
            refreshSelectedEntry()
        }
        .onDisappear {
            openFileTask?.cancel()
        }
        // Removed watcher on allEntriesCount; selectedPath changes are sufficient.
        // This avoids redundant refreshes during bulk loading.
    }

    private func isImageFile(_ name: String) -> Bool {
        let ext = name.lowercased()
        let imageExts = [".blp", ".dds", ".png", ".jpg", ".jpeg", ".gif",
                         ".webp", ".bmp", ".tga", ".tiff", ".tif", ".ico"]
        return imageExts.contains { ext.hasSuffix($0) }
    }

    @MainActor
    private func openImageFile(entry: CASCFileEntry) async {
        guard let storageService = appState.currentStorage else { return }

        if AppSettings.shared.useBuiltInImageViewer,
           let data = await storageService.readFileData(forPath: entry.normalizedPath) {
            openImageViewerWindow(fileName: entry.name, imageData: data)
            return
        }

        // Fallback to extraction for external viewer
        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CascViewer/Open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch {
            appState.errorMessage = L("create_temp_dir_failed", error.localizedDescription)
            return
        }

        let safeName = entry.name
            .components(separatedBy: "/")
            .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
            .joined(separator: "_")
        let destURL = sessionDir.appendingPathComponent(safeName)

        let extractService = CASCExtractService(storage: storageService.handle)
        let result = await extractService.extract(entries: [entry], to: sessionDir, preserveStructure: false)

        // Clean up temporary directory after a short delay regardless of outcome
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            try? FileManager.default.removeItem(at: sessionDir)
        }

        if result.wasCancelled {
            return
        } else if result.failedFiles.isEmpty {
            NSWorkspace.shared.open(destURL)
        } else {
            let reason = result.failedFiles.first?.error.localizedDescription ?? L("unknown_error")
            appState.errorMessage = L("open_failed", safeName, reason)
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
