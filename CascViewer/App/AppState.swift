import Foundation
import Combine

import CascBridge

@MainActor
final class AppState: ObservableObject {
    @Published var currentStorage: CASCStorageService?
    @Published var currentStorageHandle: CascBridge.CascStorageHandle?
    @Published var selectedPath: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
}
