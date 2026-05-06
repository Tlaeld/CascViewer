import Foundation

struct CASCFileEntry: Identifiable, Hashable, Sendable {
    let name: String
    let fullPath: String
    let normalizedPath: String
    let type: FileType
    let size: UInt64
    let encodingKey: String
    let formattedSize: String
    let isLocal: Bool

    init(name: String, fullPath: String, type: FileType, size: UInt64, encodingKey: String, isLocal: Bool = true) {
        self.name = name
        self.fullPath = fullPath
        self.normalizedPath = fullPath.replacingOccurrences(of: "\\", with: "/")
        self.type = type
        self.size = size
        self.encodingKey = encodingKey
        self.isLocal = isLocal

        if type == .directory {
            self.formattedSize = "--"
        } else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            self.formattedSize = formatter.string(fromByteCount: Int64(size))
        }
    }

    var id: String { normalizedPath }

    enum FileType: Sendable {
        case file
        case directory
    }

    var isDirectory: Bool { type == .directory }
}
