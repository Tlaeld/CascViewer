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

                Button(L("export")) {
                    exportCurrentFrame()
                }
            }
            .padding()

            Divider()

            BLPViewerView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if let info = viewModel.imageInfo {
                    let formatText: String = {
                        switch info.format {
                        case .blp2: return "BLP2"
                        case .dds: return "DDS"
                        default: return "BLP1"
                        }
                    }()
                    Text("\(L("format_label")): \(formatText)")
                    Text("\(L("size_label")): \(info.width)×\(info.height)")
                    if info.frameCount > 1 {
                        Text("\(L("frames_label")): \(info.frameCount)")
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

    private func exportCurrentFrame() {
        guard let cgImage = viewModel.currentFrame else { return }

        let panel = NSSavePanel()
        let defaultName = (fileName as NSString).deletingPathExtension + ".png"
        panel.nameFieldStringValue = defaultName

        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { [weak viewModel] result in
            guard result == .OK, let url = panel.url else { return }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                return
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            if !CGImageDestinationFinalize(destination) {
                viewModel?.errorMessage = "Export failed"
            }
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
    @Published var errorMessage: String?

    private var decodedResult: ImageDecodeResult?
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
            self.errorMessage = L("decode_failed", error.localizedDescription)
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

        // If no mipmaps, use the main frame directly
        if result.mipMaps.isEmpty {
            let frame = min(currentFrameIndex, result.frames.count - 1)
            if frame >= 0 {
                currentFrame = result.frames[frame].cgImage
            }
            return
        }

        let level = min(Int(currentMipLevel), result.mipMaps.count - 1)
        let frame = min(currentFrameIndex, result.mipMaps[level].count - 1)
        if level >= 0, frame >= 0 {
            currentFrame = result.mipMaps[level][frame].cgImage
        }
    }

    private func startAnimation() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stepFrame(delta: 1)
            }
        }
    }

    private func stopAnimation() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}

// MARK: - Window opener helper

final class ImageViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [ImageViewerWindowController] = []

    init(fileName: String, imageData: Data) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileName
        window.setContentSize(NSSize(width: 800, height: 600))
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: BLPViewerWindow(fileName: fileName, imageData: imageData))
        Self.controllers.append(self)
        window.makeKeyAndOrderFront(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        // Break the NSHostingView <-> NSWindow retain cycle and allow SwiftUI state to tear down cleanly
        window?.contentView = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.controllers.removeAll { $0 === self }
        }
    }
}

func openImageViewerWindow(fileName: String, imageData: Data) {
    _ = ImageViewerWindowController(fileName: fileName, imageData: imageData)
}
