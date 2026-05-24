import SwiftUI

struct BLPViewerView: View {
    @ObservedObject var viewModel: BLPViewerViewModel
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CheckerboardView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .drawingGroup()

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .padding()
                } else if let image = viewModel.currentFrame {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(scale)
                        .offset(offset)
                        .clipped()
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = lastScale * value
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                }
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                        .onTapGesture(count: 2) {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        }
                } else {
                    ProgressView()
                }
            }
        }
    }
}

struct CheckerboardView: View {
    private static let patternColor: NSColor = {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        NSRect(x: 16, y: 16, width: 16, height: 16).fill()
        NSColor(white: 0.7, alpha: 1).setFill()
        NSRect(x: 16, y: 0, width: 16, height: 16).fill()
        NSRect(x: 0, y: 16, width: 16, height: 16).fill()
        image.unlockFocus()
        return NSColor(patternImage: image)
    }()

    var body: some View {
        GeometryReader { _ in
            Color(Self.patternColor)
        }
    }
}
