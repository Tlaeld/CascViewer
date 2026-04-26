import SwiftUI

struct ExtractDialogView: View {
    let entries: [CASCFileEntry]
    let onExtract: (URL, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var destination = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    @State private var preserveStructure = true
    @State private var overwriteExisting = false
    @State private var openAfterExtract = false
    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Extract \(entries.count) item(s)")
                .font(.headline)

            HStack {
                Text("Destination:")
                Text(destination.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Browse...") {
                    showingPicker = true
                }
            }

            Toggle("Keep directory structure", isOn: $preserveStructure)
            Toggle("Overwrite existing files", isOn: $overwriteExisting)
            Toggle("Open destination after extraction", isOn: $openAfterExtract)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Extract") {
                    onExtract(destination, preserveStructure)
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
