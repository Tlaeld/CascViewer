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

    // Search mode (integrated into main UI, no sheet)
    @Published var isSearchMode: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [CASCFileEntry] = []
    @Published var isSearching: Bool = false
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

    @Published var language: String {
        didSet {
            defaults.set(language, forKey: "appLanguage")
            LocalizationManager.shared.loadLanguage(language)
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
        let storedTheme = defaults.string(forKey: "appTheme") ?? "system"
        self.theme = AppTheme(rawValue: storedTheme) ?? .system
        let lang = defaults.string(forKey: "appLanguage") ?? Locale.current.languageCode ?? "en"
        self.language = lang
        LocalizationManager.shared.loadLanguage(lang)
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
        theme = .system
        let lang = Locale.current.languageCode ?? "en"
        language = lang
        LocalizationManager.shared.loadLanguage(lang)
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
        [
            ("en", "English"),
            ("zh", "简体中文")
        ]
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

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private var translations: [String: String] = [:]
    private var fallback: [String: String] = [:]

    private let builtinLanguages: [String: [String: String]] = [
        "en": [
            "app_name": "CascViewer",
            "settings_title": "Settings",
            "settings_storage": "Storage",
            "settings_extraction": "Extraction",
            "settings_display": "Display",
            "settings_cache": "Cache",
            "settings_about": "About",
            "language": "Language",
            "cdn_download": "Allow CDN Download",
            "cdn_download_help": "Download missing files from CDN when browsing incomplete storages",
            "cdn_cache_path": "CDN Cache Path",
            "default_path": "Default Path",
            "keep_structure": "Keep directory structure",
            "overwrite_existing": "Overwrite existing files",
            "open_after_extract": "Open destination after extraction",
            "show_remote_markers": "Show remote file markers",
            "show_remote_markers_help": "Mark files not present locally in red with an asterisk",
            "theme": "Theme",
            "theme_light": "Light",
            "theme_dark": "Dark",
            "theme_system": "Follow System",
            "clear_cache": "Clear Download Cache",
            "reset_defaults": "Reset Defaults",
            "done": "Done",
            "casc_lib": "CascLib",
            "cache_cleared_title": "Cache Cleared",
            "cache_cleared_message": "Download cache has been cleared.",
            "ok": "OK",
            "open_storage": "Open Storage",
            "refresh": "Refresh",
            "search": "Search",
            "search_placeholder": "Search...",
            "directories": "Directories",
            "open_storage_to_browse": "Open a storage to browse",
            "extract_title": "Extract %d item(s)",
            "destination": "Destination",
            "browse": "Browse...",
            "cancel": "Cancel",
            "extract": "Extract",
            "name_column": "Name",
            "path_column": "Path",
            "size_column": "Size",
            "type_column": "Type",
            "local_column": "Local",
            "local_yes": "Yes",
            "local_no": "No",
            "folder": "Folder",
            "file": "File",
            "open": "Open",
            "download_required_title": "Download Required",
            "download_required_message": "%@ (%@) is not available locally. Download from CDN to open it?",
            "download_and_open": "Download & Open",
            "downloading_file": "Downloading %@...",
            "open_failed": "Failed to open %@: %@",
            "extract_all": "Extract All...",
            "extract_success": "Extracted %d file(s) successfully",
            "extract_partial": "Extracted %d file(s), %d failed",
            "copy_path": "Copy Path",
            "loading_storage": "Loading storage...",
            "no_storage_open": "No Storage Open",
            "root": "Root",
            "parent_directory": "Parent directory",
            "choose": "Choose",
            "status_files": "Files: %d",
            "status_storage": "Storage: %@ %@",
            "status_ready": "Ready",
            "error": "Error",
            "file_not_found": "File Not Found",
            "read_error": "Read Error",
            "unknown_error": "Unknown Error",
            "loading_file": "Loading file",
            "loading_indexes": "Loading indexes",
            "loading_manifest_encoding": "Loading manifest: ENCODING",
            "loading_manifest_download": "Loading manifest: DOWNLOAD",
            "loading_manifest_root": "Loading manifest: ROOT",
            "building_children_map": "Building directory index, this may take a moment...",
            "built_children_map": "Built children map with %d paths",
            "computed_top_level_dirs": "Computed %d top-level dirs",
            "load_root_entries_done": "loadRootEntries done, allEntries.count = %d",
            "version": "Version",
            "search_query_placeholder": "Search by name or path...",
            "search_scope_entire": "Entire Storage",
            "search_scope_current": "Current Directory",
            "search_match_options": "MATCH OPTIONS",
            "search_use_regex": "Use Regular Expressions",
            "search_case_sensitive": "Case Sensitive",
            "search_file_type": "FILE TYPE",
            "search_custom_ext": "Custom:",
            "search_custom_ext_placeholder": "ext1,ext2",
            "search_sort_by": "Sort",
            "search_sort_name": "Name",
            "search_sort_size": "Size",
            "search_sort_path": "Path",
            "search_searching": "Searching...",
            "search_result_count": "%d result(s)",
            "search_empty_prompt": "Enter a search term to begin",
            "search_no_results": "No results found",
            "search_go_to_location": "Go to Location",
            "search_failed": "Search failed: %@",
            "search_status_prefix": "Searching for",
            "search_status_results": "results",
            "details_panel": "Details",
        ],
        "zh": [
            "app_name": "CascViewer",
            "settings_title": "设置",
            "settings_storage": "存储",
            "settings_extraction": "提取",
            "settings_display": "显示",
            "settings_cache": "缓存",
            "settings_about": "关于",
            "language": "语言",
            "cdn_download": "允许 CDN 下载",
            "cdn_download_help": "浏览不完整的存储时从 CDN 下载缺失的文件",
            "cdn_cache_path": "CDN 缓存目录",
            "default_path": "默认路径",
            "keep_structure": "保留目录结构",
            "overwrite_existing": "覆盖已存在的文件",
            "open_after_extract": "提取后打开目标目录",
            "show_remote_markers": "显示远程文件标记",
            "show_remote_markers_help": "将不在本地的文件标红并带上星号",
            "theme": "主题",
            "theme_light": "浅色",
            "theme_dark": "深色",
            "theme_system": "跟随系统",
            "clear_cache": "清除下载缓存",
            "reset_defaults": "恢复默认设置",
            "done": "完成",
            "casc_lib": "CascLib",
            "cache_cleared_title": "缓存已清除",
            "cache_cleared_message": "下载缓存已被清除。",
            "ok": "确定",
            "open_storage": "打开存储",
            "refresh": "刷新",
            "search": "搜索",
            "search_placeholder": "搜索...",
            "directories": "目录",
            "open_storage_to_browse": "打开一个存储以浏览",
            "extract_title": "提取 %d 个项目",
            "destination": "目标路径",
            "browse": "浏览...",
            "cancel": "取消",
            "extract": "提取",
            "name_column": "名称",
            "path_column": "路径",
            "size_column": "大小",
            "type_column": "类型",
            "local_column": "本地",
            "local_yes": "是",
            "local_no": "否",
            "folder": "文件夹",
            "file": "文件",
            "open": "打开",
            "download_required_title": "需要下载",
            "download_required_message": "%@（%@）不在本地。从 CDN 下载并打开？",
            "download_and_open": "下载并打开",
            "downloading_file": "正在下载 %@...",
            "open_failed": "无法打开 %@：%@",
            "extract_all": "提取全部...",
            "extract_success": "成功提取 %d 个文件",
            "extract_partial": "提取了 %d 个文件，%d 个失败",
            "copy_path": "复制路径",
            "loading_storage": "正在加载存储...",
            "no_storage_open": "未打开存储",
            "root": "根目录",
            "parent_directory": "上级目录",
            "choose": "选择",
            "status_files": "文件: %d",
            "status_storage": "存储: %@ %@",
            "status_ready": "就绪",
            "error": "错误",
            "file_not_found": "文件未找到",
            "read_error": "读取错误",
            "unknown_error": "未知错误",
            "loading_file": "正在加载文件",
            "loading_indexes": "正在加载索引",
            "loading_manifest_encoding": "正在加载清单: ENCODING",
            "loading_manifest_download": "正在加载清单: DOWNLOAD",
            "loading_manifest_root": "正在加载清单: ROOT",
            "building_children_map": "正在构建目录索引，这需要一点时间...",
            "built_children_map": "已构建子目录映射，共 %d 条路径",
            "computed_top_level_dirs": "计算了 %d 个顶层目录",
            "load_root_entries_done": "loadRootEntries 完成，allEntries.count = %d",
            "version": "版本",
            "search_query_placeholder": "按名称或路径搜索...",
            "search_scope_entire": "全部存储",
            "search_scope_current": "当前目录",
            "search_match_options": "匹配选项",
            "search_use_regex": "使用正则表达式",
            "search_case_sensitive": "区分大小写",
            "search_file_type": "文件类型",
            "search_custom_ext": "自定义：",
            "search_custom_ext_placeholder": "扩展名1,扩展名2",
            "search_sort_by": "排序",
            "search_sort_name": "名称",
            "search_sort_size": "大小",
            "search_sort_path": "路径",
            "search_searching": "搜索中...",
            "search_result_count": "%d 个结果",
            "search_empty_prompt": "输入搜索词开始搜索",
            "search_no_results": "未找到结果",
            "search_go_to_location": "跳转到位置",
            "search_failed": "搜索失败：%@",
            "search_status_prefix": "正在搜索",
            "search_status_results": "结果",
            "details_panel": "详情",
        ]
    ]

    private init() {
        loadLanguage("en")
    }

    func loadLanguage(_ code: String) {
        fallback = builtinLanguages["en"] ?? [:]
        translations = builtinLanguages[code] ?? fallback

        // Allow user-defined overrides from disk
        if let override = loadOverride(for: code) {
            for (key, value) in override {
                translations[key] = value
            }
        }
    }

    private func loadOverride(for code: String) -> [String: String]? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let path = support.appendingPathComponent("CascViewer/Lang/\(code).json").path
        guard fm.fileExists(atPath: path) else { return nil }

        // Limit file size to prevent OOM from malicious large JSON files (max 1 MB)
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.intValue > 0 && fileSize.intValue <= 1_048_576 else {
            return nil
        }

        guard let data = fm.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return json
    }

    func string(_ key: String, _ args: CVarArg...) -> String {
        let template = translations[key] ?? fallback[key] ?? key
        return String(format: template, locale: Locale.current, arguments: args)
    }

    var availableLanguages: [(code: String, name: String)] {
        [
            ("en", "English"),
            ("zh", "简体中文")
        ]
    }
}

/// Convenience global function for localized strings.
func L(_ key: String, _ args: CVarArg...) -> String {
    LocalizationManager.shared.string(key, args)
}
