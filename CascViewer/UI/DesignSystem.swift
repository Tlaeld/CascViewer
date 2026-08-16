import SwiftUI
import AppKit

/// 主窗口与搜索窗口的统一设计 token。
/// 视图一律引用这里的常量,不再散落硬编码的字体大小/颜色/间距。
enum DS {

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    enum Corner {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
    }

    enum Fonts {
        /// 区块标题(如"目录"、"详情")
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
        /// 面板主标题(如详情面板文件名)
        static let title = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 12)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11)
        /// 等宽(编码密钥等)
        static let mono = Font.system(size: 11, design: .monospaced)
    }

    enum Colors {
        static let panelBackground = Color(NSColor.controlBackgroundColor)
        static let remoteFile = Color(NSColor.systemRed)
        static let localYes = Color(NSColor.systemGreen)
        static let localNo = Color(NSColor.systemOrange)
        static let folderIcon = Color(NSColor.controlAccentColor)
        static let fileIcon = Color(NSColor.secondaryLabelColor)
        static let rowText = Color(NSColor.labelColor)
        static let secondaryText = Color(NSColor.secondaryLabelColor)
    }

    /// AppKit cell 用的同一套颜色(NSTableView/NSOutlineView 桥接层)。
    enum NSColors {
        static let remoteFile = NSColor.systemRed
        static let localYes = NSColor.systemGreen
        static let localNo = NSColor.systemOrange
        static let folderIcon = NSColor.controlAccentColor
        static let fileIcon = NSColor.secondaryLabelColor
        static let rowText = NSColor.labelColor
        static let secondaryText = NSColor.secondaryLabelColor
    }

    /// AppKit cell 行文字号。
    static let rowFontSize: CGFloat = 12
}
