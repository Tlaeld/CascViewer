import SwiftUI

struct BLPAnimationControls: View {
    @ObservedObject var viewModel: BLPViewerViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.togglePlayback() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }

            Button(action: { viewModel.stepFrame(delta: -1) }) {
                Image(systemName: "backward.frame.fill")
            }

            Button(action: { viewModel.stepFrame(delta: 1) }) {
                Image(systemName: "forward.frame.fill")
            }
        }
    }
}
