import SwiftUI

struct BLPViewerView: View {
    @ObservedObject var viewModel: BLPViewerViewModel
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CheckerboardView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let image = viewModel.currentFrame {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = value
                                }
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    offset = value.translation
                                }
                        )
                        .onTapGesture(count: 2) {
                            scale = 1.0
                            offset = .zero
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
