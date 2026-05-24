import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        let cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("CascViewer").path
        cdnDownloadEnabled = true
        cdnCachePath = cachePath ?? ""
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

    @discardableResult
    func clearCache(baseDirectory: URL? = nil) -> Bool {
        let fileManager = FileManager.default
        var overallSuccess = true
        // Only remove CascViewer's own cache directories, not the entire system cache
        let cachesDir = baseDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cachesDir = cachesDir {
            let cascCache = cachesDir.appendingPathComponent("CascViewer")
            if fileManager.fileExists(atPath: cascCache.path) {
                do {
                    try fileManager.removeItem(at: cascCache)
                } catch {
                    overallSuccess = false
                }
            }
        }
        if let appSupport = baseDirectory == nil ? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first : nil {
            let cascCache = appSupport.appendingPathComponent("CascViewer/Cache")
            if fileManager.fileExists(atPath: cascCache.path) {
                do {
                    try fileManager.removeItem(at: cascCache)
                } catch {
                    overallSuccess = false
                }
            }
        }
        return overallSuccess
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
