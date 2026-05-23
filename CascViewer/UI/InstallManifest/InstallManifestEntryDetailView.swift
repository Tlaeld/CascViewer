import SwiftUI
import AppKit
import CascBridge

struct InstallManifestEntryDetailView: View {
    let entry: InstallManifestEntry
    let tags: [InstallManifestTag]
    let storageService: CASCStorageService?
    @Environment(\.dismiss) private var dismiss
    @State private var fileExists = false
    @State private var actualSize: UInt64?
    @State private var isLocal = false

    var ownedTags: [InstallManifestTag] {
        tags.enumerated().compactMap { index, tag in
            entry.hasTag(at: index) ? tag : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("file_details"))
                    .font(.title2)
                Spacer()
                Button(L("close")) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DetailSection(title: L("basic_info")) {
                        DetailRow(label: L("file_name"), value: entry.fileName)
                        DetailRow(label: L("file_size"), value: entry.formattedSize)
                        DetailRow(label: L("ckey"), value: entry.ckey)
                        if let actualSize = actualSize {
                            DetailRow(label: L("actual_size"), value: ByteCountFormatter().string(fromByteCount: Int64(actualSize)))
                        }
                        if storageService != nil {
                            HStack {
                                Text(L("file_status"))
                                    .foregroundColor(.secondary)
                                    .frame(width: 100, alignment: .trailing)
                                HStack(spacing: 4) {
                                    Image(systemName: fileExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(fileExists ? .green : .red)
                                    Text(fileExists ? L("available") : L("not_available"))
                                }
                            }
                        }
                    }

                    if !ownedTags.isEmpty {
                        DetailSection(title: L("tags")) {
                            FlowLayout(spacing: 8) {
                                ForEach(ownedTags) { tag in
                                    Text(tag.name)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            checkFileAvailability()
        }
    }

    private func checkFileAvailability() {
        guard let service = storageService else { return }
        Task {
            let path = entry.fileName.replacingOccurrences(of: "/", with: "\\")
            var error = CascBridge.CascError.None
            var handle = service.handle
            // Read a single byte to check existence without pulling the whole file into memory
            _ = handle.readFilePartial(std.string(path), 0, 1, &error)
            let exists = error == .None
            await MainActor.run {
                self.fileExists = exists
                self.actualSize = exists ? UInt64(self.entry.fileSize) : nil
            }
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(nil)
            Spacer()
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
