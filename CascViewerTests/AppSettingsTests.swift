import XCTest
@testable import CascViewer

@MainActor
final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "test.CascViewer.AppSettings"
    private var originalLanguageCode: String!

    override func setUp() {
        super.setUp()
        originalLanguageCode = LocalizationManager.shared.languageCode
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        LocalizationManager.shared.languageCode = originalLanguageCode
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultValues() {
        // Verify that AppSettings initializes with reasonable defaults
        AppSettings.shared.resetToDefaults()
        let settings = AppSettings.shared
        XCTAssertTrue(settings.cdnDownloadEnabled)
        XCTAssertTrue(settings.showRemoteMarkers)
        XCTAssertTrue(settings.useBuiltInImageViewer)
        XCTAssertTrue(settings.preserveStructure)
        XCTAssertFalse(settings.overwriteExisting)
        XCTAssertFalse(settings.openAfterExtract)
        XCTAssertEqual(settings.theme, .system)
    }

    func testAvailableLanguages() {
        let languages = AppSettings.shared.availableLanguages
        XCTAssertEqual(languages.count, 2)
        XCTAssertTrue(languages.contains(where: { $0.code == "en" }))
        XCTAssertTrue(languages.contains(where: { $0.code == "zh-Hans" }))
    }

    func testDefaultExtractURL() {
        let settings = AppSettings.shared
        let url = settings.defaultExtractURL
        XCTAssertTrue(url.isFileURL)
        XCTAssertFalse(url.path.isEmpty)
    }

    func testLanguageNormalization() {
        // AppSettings normalizes "zh" to "zh-Hans"
        let manager = LocalizationManager.shared
        manager.languageCode = "zh"
        XCTAssertEqual(manager.languageCode, "zh-Hans")
    }

    func testLocalizationWithArgs() {
        let format = L("search_result_count", 42)
        XCTAssertTrue(format.contains("42"))
    }

    func testLocalizationFallback() {
        // Missing key should return the key itself
        let result = L("nonexistent_key_xyz")
        XCTAssertEqual(result, "nonexistent_key_xyz")
    }

    func testThemeColorScheme() {
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
        XCTAssertNil(AppTheme.system.colorScheme)
    }

    func testThemeLocalizationKey() {
        XCTAssertEqual(AppTheme.light.localizationKey, "theme_light")
        XCTAssertEqual(AppTheme.dark.localizationKey, "theme_dark")
        XCTAssertEqual(AppTheme.system.localizationKey, "theme_system")
    }
}
