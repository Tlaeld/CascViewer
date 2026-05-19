import Foundation
import Combine
import SwiftUI

import CascBridge

@MainActor
final class AppState: ObservableObject {
    @Published var currentStorage: CASCStorageService?
    @Published var selectedPath: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Search mode (integrated into main UI, persistent state)
    @Published var isSearchMode: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchMode: SearchMode = .filename
    @Published var searchScope: SearchScope = .entireStorage
    @Published var searchUseRegex: Bool = false
    @Published var searchCaseSensitive: Bool = false
    @Published var searchIncludePath: Bool = false
    @Published var searchSelectedTypes: Set<String> = []
    @Published var searchCustomExtension: String = ""
    @Published var searchSelectedTags: Set<String> = []
    @Published var searchResults: [SearchMatch] = []
    @Published var searchIsSearching: Bool = false
    @Published var searchSortBy: SearchSortBy = .name
    @Published var searchSortAscending: Bool = true


}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var cdnDownloadEnabled: Bool {
        didSet { defaults.set(cdnDownloadEnabled, forKey: "cdnDownloadEnabled") }
    }
    @Published var cdnCachePath: String {
        didSet { defaults.set(cdnCachePath, forKey: "cdnCachePath") }
    }
    @Published var defaultExtractPath: String {
        didSet { defaults.set(defaultExtractPath, forKey: "defaultExtractPath") }
    }
    @Published var preserveStructure: Bool {
        didSet { defaults.set(preserveStructure, forKey: "preserveStructure") }
    }
    @Published var overwriteExisting: Bool {
        didSet { defaults.set(overwriteExisting, forKey: "overwriteExisting") }
    }
    @Published var openAfterExtract: Bool {
        didSet { defaults.set(openAfterExtract, forKey: "openAfterExtract") }
    }
    @Published var showRemoteMarkers: Bool {
        didSet { defaults.set(showRemoteMarkers, forKey: "showRemoteMarkers") }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "appTheme") }
    }

    @Published var useBuiltInImageViewer: Bool {
        didSet { defaults.set(useBuiltInImageViewer, forKey: "useBuiltInImageViewer") }
    }

    @Published var language: String {
        didSet {
            let code = (language == "zh") ? "zh-Hans" : language
            defaults.set(code, forKey: "appLanguage")
            LocalizationManager.shared.languageCode = code
        }
    }

    private init() {
        self.cdnDownloadEnabled = defaults.object(forKey: "cdnDownloadEnabled") as? Bool ?? true
        let cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("CascViewer").path
        self.cdnCachePath = defaults.string(forKey: "cdnCachePath") ?? (cachePath ?? "")
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.temporaryDirectory.path
        self.defaultExtractPath = defaults.string(forKey: "defaultExtractPath") ?? desktopPath
        self.preserveStructure = defaults.object(forKey: "preserveStructure") as? Bool ?? true
        self.overwriteExisting = defaults.object(forKey: "overwriteExisting") as? Bool ?? false
        self.openAfterExtract = defaults.object(forKey: "openAfterExtract") as? Bool ?? false
        self.showRemoteMarkers = defaults.object(forKey: "showRemoteMarkers") as? Bool ?? true
        self.useBuiltInImageViewer = defaults.object(forKey: "useBuiltInImageViewer") as? Bool ?? true
        let storedTheme = defaults.string(forKey: "appTheme") ?? "system"
        self.theme = AppTheme(rawValue: storedTheme) ?? .system
        let storedLang = defaults.string(forKey: "appLanguage") ?? Locale.current.languageCode ?? "en"
        let normalizedLang = (storedLang == "zh") ? "zh-Hans" : storedLang
        self.language = normalizedLang
        LocalizationManager.shared.languageCode = normalizedLang
    }

    var defaultExtractURL: URL {
        URL(fileURLWithPath: defaultExtractPath)
    }

    func resetToDefaults() {
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.temporaryDirectory.path
        cdnDownloadEnabled = true
        cdnCachePath = ""
        defaultExtractPath = desktopPath
        preserveStructure = true
        overwriteExisting = false
        openAfterExtract = false
        showRemoteMarkers = true
        useBuiltInImageViewer = true
        theme = .system
        let lang = Locale.current.languageCode ?? "en"
        language = lang
        LocalizationManager.shared.languageCode = lang
    }

    func clearCache() {
        let fileManager = FileManager.default
        // Only remove CascViewer's own cache directories, not the entire system cache
        if let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cascCache = cachesDir.appendingPathComponent("CascViewer")
            if fileManager.fileExists(atPath: cascCache.path) {
                try? fileManager.removeItem(at: cascCache)
            }
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let cascCache = appSupport.appendingPathComponent("CascViewer/Cache")
            if fileManager.fileExists(atPath: cascCache.path) {
                try? fileManager.removeItem(at: cascCache)
            }
        }
    }

    var availableLanguages: [(code: String, name: String)] {
        LocalizationManager.shared.availableLanguages
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Follow System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var localizationKey: String {
        switch self {
        case .light: return "theme_light"
        case .dark: return "theme_dark"
        case .system: return "theme_system"
        }
    }
}
import Foundation

final class LocalizationManager {
    static let shared = LocalizationManager()

    var languageCode: String = "en" {
        didSet {
            if languageCode == "zh" { languageCode = "zh-Hans" }
            _cachedBundle = nil
        }
    }

    private var _cachedBundle: Bundle?

    private var localizedBundle: Bundle {
        if let cached = _cachedBundle { return cached }
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            _cachedBundle = Bundle.main
            return Bundle.main
        }
        _cachedBundle = bundle
        return bundle
    }

    func string(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: nil, bundle: localizedBundle, comment: "")
        return String(format: format, locale: Locale.current, arguments: args)
    }

    var availableLanguages: [(code: String, name: String)] {
        [
            ("en", "English"),
            ("zh-Hans", "简体中文")
        ]
    }
}

/// Convenience global function for localized strings.
func L(_ key: String, _ args: CVarArg...) -> String {
    LocalizationManager.shared.string(key, args)
}
