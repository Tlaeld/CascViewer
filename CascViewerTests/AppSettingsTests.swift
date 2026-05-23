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
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.cdnDownloadEnabled)
        XCTAssertTrue(settings.showRemoteMarkers)
        XCTAssertTrue(settings.useBuiltInImageViewer)
        XCTAssertTrue(settings.preserveStructure)
        XCTAssertFalse(settings.overwriteExisting)
        XCTAssertFalse(settings.openAfterExtract)
        XCTAssertEqual(settings.theme, .system)
    }

    func testAvailableLanguages() {
        let settings = AppSettings(defaults: defaults)
        let languages = settings.availableLanguages
        XCTAssertTrue(languages.count >= 2)
        XCTAssertTrue(languages.contains(where: { $0.code == "en" }))
        XCTAssertTrue(languages.contains(where: { $0.code == "zh-Hans" }))
    }

    func testDefaultExtractURL() {
        let settings = AppSettings(defaults: defaults)
        let url = settings.defaultExtractURL
        XCTAssertTrue(url.isFileURL)
        XCTAssertFalse(url.path.isEmpty)
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.temporaryDirectory.path
        XCTAssertEqual(url.path, desktopPath)
    }

    func testLanguageNormalization() {
        let settings = AppSettings(defaults: defaults)
        settings.language = "zh"
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "zh-Hans")
        XCTAssertEqual(LocalizationManager.shared.languageCode, "zh-Hans")
    }

    func testLocalizationWithArgs() {
        let settings = AppSettings(defaults: defaults)
        settings.language = "en"
        let format = L("search_result_count", 42)
        XCTAssertTrue(format.contains("42"))
    }

    func testLocalizationFallback() {
        let settings = AppSettings(defaults: defaults)
        settings.language = "en"
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

    func testClearCache() {
        let settings = AppSettings(defaults: defaults)
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cascCache = tempDir.appendingPathComponent("CascViewer")
        let dummyFile = cascCache.appendingPathComponent("dummy.txt")
        try? fm.createDirectory(at: cascCache, withIntermediateDirectories: true)
        try? "test".write(to: dummyFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(fm.fileExists(atPath: dummyFile.path))

        settings.clearCache(baseDirectory: tempDir)

        XCTAssertFalse(fm.fileExists(atPath: dummyFile.path))
    }
}
