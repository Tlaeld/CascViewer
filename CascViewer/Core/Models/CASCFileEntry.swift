import Foundation

public enum CascNameType: UInt8, Sendable {
    case full = 0
    case dataId = 1
    case ckey = 2
    case ekey = 3
}

public struct CASCFileEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let fullPath: String
    public let type: FileType
    public let size: UInt64
    public let encodingKey: String
    public let isLocal: Bool
    public let nameType: CascNameType

    public var normalizedPath: String { fullPath.replacingOccurrences(of: "\\", with: "/") }
    public var formattedSize: String {
        if type == .directory { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    public init(name: String, fullPath: String, type: FileType, size: UInt64, encodingKey: String, isLocal: Bool = true, nameType: CascNameType = .full) {
        self.name = name
        self.fullPath = fullPath
        self.type = type
        self.size = size
        self.encodingKey = encodingKey
        self.isLocal = isLocal
        self.nameType = nameType
    }

    public var id: String { fullPath.replacingOccurrences(of: "\\", with: "/") }

    public enum FileType: Sendable {
        case file
        case directory
    }

    public var isDirectory: Bool { type == .directory }
}
