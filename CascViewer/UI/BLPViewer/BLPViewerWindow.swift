import SwiftUI

struct BLPViewerWindow: View {
    let fileName: String
    let imageData: Data
    @StateObject private var viewModel = BLPViewerViewModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fileName)
                    .font(.headline)

                Spacer()

                if viewModel.imageInfo?.frameCount ?? 0 > 1 {
                    BLPAnimationControls(viewModel: viewModel)
                }

                BLPMipMapSelector(viewModel: viewModel)

                Button("Export") {
                    viewModel.showingExportPanel = true
                }
            }
            .padding()

            Divider()

            BLPViewerView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if let info = viewModel.imageInfo {
                    Text("Format: \(info.format == .blp2 ? "BLP2" : "BLP1")")
                    Text("Size: \(info.width)×\(info.height)")
                    if info.frameCount > 1 {
                        Text("Frames: \(info.frameCount)")
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 600, minHeight: 500)
        .task {
            await viewModel.loadFile(data: imageData)
        }
    }
}

@MainActor
class BLPViewerViewModel: ObservableObject {
    @Published var imageInfo: BLPImageInfo?
    @Published var currentFrame: CGImage?
    @Published var currentMipLevel: UInt32 = 0 {
        didSet {
            updateCurrentFrame()
        }
    }
    @Published var isPlaying = false
    @Published var currentFrameIndex = 0
    @Published var showingExportPanel = false
    @Published var errorMessage: String?

    private var decodedResult: BLPDecodeResult?
    private var playbackTimer: Timer?

    deinit {
        playbackTimer?.invalidate()
    }

    func loadFile(data: Data) async {
        let coordinator = BLPDecoderCoordinator()
        do {
            let result = try await coordinator.decode(data: data)
            self.decodedResult = result
            self.imageInfo = BLPImageInfo(
                format: result.format,
                width: result.width,
                height: result.height,
                mipLevels: result.mipLevels,
                frameCount: result.frameCount,
                hasAlpha: result.hasAlpha
            )
            self.updateCurrentFrame()
        } catch {
            self.errorMessage = "Failed to decode BLP: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    func stepFrame(delta: Int) {
        guard let result = decodedResult else { return }
        let frameCount = Int(result.frameCount)
        currentFrameIndex = (currentFrameIndex + delta + frameCount) % frameCount
        updateCurrentFrame()
    }

    private func updateCurrentFrame() {
        guard let result = decodedResult else { return }
        let level = min(Int(currentMipLevel), result.mipMaps.count - 1)
        let frame = min(currentFrameIndex, result.mipMaps[level].count - 1)
        if level >= 0, frame >= 0 {
            currentFrame = result.mipMaps[level][frame].cgImage
        }
    }

    private func startAnimation() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.stepFrame(delta: 1)
        }
    }

    private func stopAnimation() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}
