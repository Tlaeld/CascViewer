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
    let squareSize: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let cols = Int(geometry.size.width / squareSize) + 1
            let rows = Int(geometry.size.height / squareSize) + 1

            Canvas { context, size in
                for row in 0..<rows {
                    for col in 0..<cols {
                        let rect = CGRect(
                            x: CGFloat(col) * squareSize,
                            y: CGFloat(row) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )
                        let isDark = (row + col) % 2 == 0
                        context.fill(
                            Path(rect),
                            with: .color(isDark ? Color(white: 0.9) : Color(white: 0.7))
                        )
                    }
                }
            }
        }
    }
}
