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
