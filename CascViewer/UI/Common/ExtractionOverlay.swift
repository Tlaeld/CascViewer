import SwiftUI

struct ExtractionOverlay: View {
    let service: CASCExtractService?
    let titleKey: String
    let width: CGFloat
    let showPercentage: Bool

    var body: some View {
        if let service = service, service.isExtracting {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(L(titleKey, service.currentFile))
                        .font(.headline)
                        .foregroundColor(.primary)
                    ProgressView(value: service.progress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: width)
                    if showPercentage {
                        Text("\(Int(max(0, min(service.progress, 1)) * 100))%")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Button(L("cancel")) {
                        service.cancel()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(24)
                .frame(width: max(width + 40, 340))
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 20)
            }
        }
    }
}
