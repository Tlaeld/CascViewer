import SwiftUI
import AppKit
import CascBridge

@MainActor
final class InstallManifestExtractService: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    @Published var isExporting: Bool = false

    private class ProgressContext {
        weak var service: InstallManifestExtractService?
        let fileIndex: Int
        let totalFiles: Int

        init(service: InstallManifestExtractService, fileIndex: Int, totalFiles: Int) {
            self.service = service
            self.fileIndex = fileIndex
            self.totalFiles = totalFiles
        }
    }

    func extract(entries: [InstallManifestEntry], destination: URL, preserveStructure: Bool, storageService: CASCStorageService) async -> (success: Int, skipped: Int, failed: [String]) {
        isExporting = true
        progress = 0
        defer { isExporting = false }

        let total = entries.count
        var failed: [String] = []
        var skipped = 0

        for (index, entry) in entries.enumerated() {
            await MainActor.run {
                progress = Double(index) / Double(total)
                currentFile = entry.fileName
            }

            // Use CKey as cascPath so CascLib can find files not in ROOT handler
            let cascPath = entry.ckey
            let destPath: String
            if preserveStructure {
                destPath = destination.appendingPathComponent(entry.fileName).path
            } else {
                let safeName = entry.fileName.components(separatedBy: "/").last ?? entry.fileName
                destPath = destination.appendingPathComponent(safeName).path
            }

            let parentDir = URL(fileURLWithPath: destPath).deletingLastPathComponent().path
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: parentDir), withIntermediateDirectories: true)

            var handle = storageService.handle

            let error: CascBridge.CascError = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let progressCtx = ProgressContext(service: self, fileIndex: index, totalFiles: total)
                    let rawContext = Unmanaged.passUnretained(progressCtx).toOpaque()

                    let progressBlock: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64) -> Void = { context, current, totalBytes in
                        guard let ctxPtr = context else { return }
                        guard totalBytes > 0 else { return }
                        let ctx = Unmanaged<ProgressContext>.fromOpaque(ctxPtr).takeUnretainedValue()
                        guard let service = ctx.service else { return }
                        let fileProgress = Double(current) / Double(totalBytes)
                        let overallProgress = (Double(ctx.fileIndex) + fileProgress) / Double(ctx.totalFiles)
                        if ctx.fileIndex == 0 || current == totalBytes {
                            NSLog("[InstallManifestExtract] progress callback: file \(ctx.fileIndex)/\(ctx.totalFiles), current=\(current), total=\(totalBytes), overall=\(overallProgress)")
                        }
                        DispatchQueue.main.async {
                            service.progress = overallProgress
                        }
                    }

                    let result = handle.extractFile(
                        std.string(cascPath),
                        std.string(destPath),
                        progressBlock,
                        rawContext
                    )
                    continuation.resume(returning: result)
                }
            }

            if error == .FileNotFound {
                NSLog("[InstallManifestExtract] file \(index): \(entry.fileName) -> FileNotFound (skipped)")
                skipped += 1
                continue
            } else if error != .None {
                let reason = error.localizedDescription
                NSLog("[InstallManifestExtract] file \(index): \(entry.fileName) -> error: \(reason) (raw: \(error))")
                failed.append("\(entry.fileName): \(reason)")
            } else {
                NSLog("[InstallManifestExtract] file \(index): \(entry.fileName) -> success")
            }
        }

        return (success: entries.count - failed.count - skipped, skipped: skipped, failed: failed)
    }
}

struct ExportSheetConfig: Identifiable {
    let id = UUID()
    let entries: [InstallManifestEntry]
}

struct InstallManifestExportSheet: View {
    let entries: [InstallManifestEntry]
    let storageService: CASCStorageService?
    let onComplete: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL
    @State private var preserveStructure = true
    @State private var showingPicker = false
    @StateObject private var extractService = InstallManifestExtractService()
    @State private var showingDownloadConfirm = false
    @State private var remoteEntries: [InstallManifestEntry] = []
    @State private var exportResult: (success: Int, skipped: Int, failed: [String])? = nil

    init(entries: [InstallManifestEntry], storageService: CASCStorageService?, onComplete: @escaping (String?) -> Void) {
        self.entries = entries
        self.storageService = storageService
        self.onComplete = onComplete
        let defaultURL = AppSettings.shared.defaultExtractURL
        _destination = State(initialValue: defaultURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("export_title", entries.count))
                .font(.headline)

            if let result = exportResult {
                // Result view
                resultView(result)
            } else {
                // Export config view
                HStack {
                    Text(L("destination") + ":")
                    Text(destination.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L("browse")) {
                        showingPicker = true
                    }
                }

                Toggle(L("keep_structure"), isOn: $preserveStructure)

                if extractService.isExporting {
                    VStack(spacing: 8) {
                        ProgressView(value: extractService.progress, total: 1.0)
                        Text(extractService.currentFile)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button(L("cancel")) { dismiss() }
                        .disabled(extractService.isExporting)
                    Button(L("export")) {
                        performExport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(extractService.isExporting || storageService == nil)
                }
            }
        }
        .padding()
        .frame(width: 450)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                destination = url
            }
        }
        .alert(L("download_required_title"), isPresented: $showingDownloadConfirm, presenting: remoteEntries) { entries in
            Button(L("download_and_export"), role: .none) {
                performExport()
            }
            Button(L("cancel"), role: .cancel) { }
        } message: { entries in
            let totalSize = entries.reduce(0) { $0 + Int64($1.fileSize) }
            let sizeStr = ByteCountFormatter().string(fromByteCount: totalSize)
            Text(L("download_required_export_message", entries.count, sizeStr))
        }
    }

    @ViewBuilder
    private func resultView(_ result: (success: Int, skipped: Int, failed: [String])) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.success > 0 {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(L("extract_success", result.success))
                }
            }

            if result.skipped > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L("extract_skipped", result.skipped))
                }
            }

            if !result.failed.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("extract_partial", result.success, result.failed.count))
                            .foregroundColor(.red)
                        ForEach(result.failed.prefix(5), id: \.self) { msg in
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if result.failed.count > 5 {
                            Text("... \(result.failed.count - 5) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(L("done")) {
                    var parts: [String] = []
                    if result.success > 0 {
                        parts.append(L("extract_success", result.success))
                    }
                    if result.skipped > 0 {
                        parts.append(L("extract_skipped", result.skipped))
                    }
                    if !result.failed.isEmpty {
                        let failedMsg = result.failed.prefix(5).joined(separator: "\n") + (result.failed.count > 5 ? "\n... \(result.failed.count - 5) more" : "")
                        parts.append(L("extract_partial", result.success, result.failed.count) + "\n" + failedMsg)
                    }
                    onComplete(parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func performExport() {
        guard let service = storageService else { return }

        // Check if any files are not local
        let remote = entries.filter { entry in
            guard let fileEntry = service.entry(forPath: entry.fileName) else { return true }
            return !fileEntry.isLocal
        }

        NSLog("[InstallManifestExport] total entries: \(entries.count), remote: \(remote.count), isOnline: \(service.isOnlineStorage)")

        // Local storage cannot download missing files from CDN
        if !service.isOnlineStorage && !remote.isEmpty {
            Task {
                let localEntries = entries.filter { entry in
                    guard let fileEntry = service.entry(forPath: entry.fileName) else { return false }
                    return fileEntry.isLocal
                }
                let localResult = await extractService.extract(
                    entries: localEntries,
                    destination: destination,
                    preserveStructure: preserveStructure,
                    storageService: service
                )
                var failed = localResult.failed
                if !remote.isEmpty {
                    failed.append(L("local_storage_cannot_download", remote.count))
                }
                await MainActor.run {
                    exportResult = (
                        success: localResult.success,
                        skipped: localResult.skipped,
                        failed: failed
                    )
                }
            }
            return
        }

        // Online storage: show download confirmation if needed
        if !remote.isEmpty && !showingDownloadConfirm {
            remoteEntries = remote
            showingDownloadConfirm = true
            return
        }

        Task {
            let result = await extractService.extract(
                entries: entries,
                destination: destination,
                preserveStructure: preserveStructure,
                storageService: service
            )

            await MainActor.run {
                exportResult = result
            }
        }
    }
}
