import SwiftUI

struct ExtractDialogView: View {
    let entries: [CASCFileEntry]
    let onExtract: (URL, Bool, Bool, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL
    @State private var preserveStructure: Bool
    @State private var overwriteExisting: Bool
    @State private var openAfterExtract: Bool
    @State private var showingPicker = false

    init(entries: [CASCFileEntry], onExtract: @escaping (URL, Bool, Bool, Bool) -> Void) {
        self.entries = entries
        self.onExtract = onExtract
        let defaultURL = AppSettings.shared.defaultExtractURL
        _destination = State(initialValue: defaultURL)
        _preserveStructure = State(initialValue: AppSettings.shared.preserveStructure)
        _overwriteExisting = State(initialValue: AppSettings.shared.overwriteExisting)
        _openAfterExtract = State(initialValue: AppSettings.shared.openAfterExtract)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("extract_title", entries.count))
                .font(.headline)

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
            Toggle(L("overwrite_existing"), isOn: $overwriteExisting)
            Toggle(L("open_after_extract"), isOn: $openAfterExtract)

            HStack {
                Spacer()
                Button(L("cancel")) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(L("extract")) {
                    onExtract(destination, preserveStructure, overwriteExisting, openAfterExtract)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
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
    }
}
