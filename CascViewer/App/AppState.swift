import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var currentStorage: CASCStorageService?
    @Published var selectedPath: URL?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
}
