import Foundation

public enum CascNameType: UInt8, Sendable {
    case full = 0
    case dataId = 1
    case ckey = 2
    case ekey = 3
}

public struct InstallManifestTag: Identifiable, Hashable, Sendable {
    public let name: String
    public let value: UInt32
    
    public var id: String { name }
    
    public init(name: String, value: UInt32 = 0) {
        self.name = name
        self.value = value
    }
}

public struct InstallManifestEntry: Identifiable, Hashable, Sendable {
    public let fileName: String
    public let ckey: String
    public let fileSize: UInt32
    public let tagBits: [Bool]
    
    public var id: String { fileName }
    
    public init(fileName: String, ckey: String, fileSize: UInt32, tagBits: [Bool]) {
        self.fileName = fileName
        self.ckey = ckey
        self.fileSize = fileSize
        self.tagBits = tagBits
    }
    
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }
    
    public func hasTag(at index: Int) -> Bool {
        guard index >= 0 && index < tagBits.count else { return false }
        return tagBits[index]
    }
}

public struct CASCFileEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let fullPath: String
    public let type: FileType
    public let size: UInt64
    public let encodingKey: String
    public let isLocal: Bool
    public let nameType: CascNameType
    public let tagBitMask: UInt64

    public var normalizedPath: String { fullPath.replacingOccurrences(of: "\\", with: "/") }
    public var formattedSize: String {
        if type == .directory { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    public init(name: String, fullPath: String, type: FileType, size: UInt64, encodingKey: String, isLocal: Bool = true, nameType: CascNameType = .full, tagBitMask: UInt64 = 0) {
        self.name = name
        self.fullPath = fullPath
        self.type = type
        self.size = size
        self.encodingKey = encodingKey
        self.isLocal = isLocal
        self.nameType = nameType
        self.tagBitMask = tagBitMask
    }

    public var id: String { fullPath.replacingOccurrences(of: "\\", with: "/") }

    public enum FileType: Sendable {
        case file
        case directory
    }

    public var isDirectory: Bool { type == .directory }
}
