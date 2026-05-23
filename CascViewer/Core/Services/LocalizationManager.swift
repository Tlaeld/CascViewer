import Foundation

final class LocalizationManager {
    static let shared = LocalizationManager()

    private let lock = NSLock()
    private var _languageCode: String = "en"
    private var _cachedBundle: Bundle?

    var languageCode: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _languageCode
        }
        set {
            let code = (newValue == "zh") ? "zh-Hans" : newValue
            lock.lock()
            _languageCode = code
            _cachedBundle = nil
            lock.unlock()
        }
    }

    private var localizedBundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _cachedBundle { return cached }
        guard let path = Bundle.main.path(forResource: _languageCode, ofType: "lproj"),
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
