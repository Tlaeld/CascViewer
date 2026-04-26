import SwiftUI

struct BLPMipMapSelector: View {
    @ObservedObject var viewModel: BLPViewerViewModel

    var body: some View {
        Picker("MIP", selection: $viewModel.currentMipLevel) {
            if let info = viewModel.imageInfo {
                ForEach(0..<Int(info.mipLevels), id: \.self) { level in
                    let size = Int(Double(info.width) / pow(2.0, Double(level)))
                    Text("\(size)×\(size)")
                        .tag(UInt32(level))
                }
            }
        }
        .pickerStyle(.menu)
        .frame(width: 120)
    }
}
