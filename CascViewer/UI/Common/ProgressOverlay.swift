import SwiftUI

struct ProgressOverlay: View {
    let title: String
    let message: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)

            ProgressView(value: progress)
                .frame(width: 200)

            Button("Cancel") {
                onCancel()
            }
        }
        .padding(24)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.2))
    }
}
