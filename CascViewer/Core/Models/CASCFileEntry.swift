import Foundation

struct CASCFileEntry: Identifiable, Hashable, Sendable {
    let name: String
    let fullPath: String
    let type: FileType
    let size: UInt64
    let encodingKey: String
    let formattedSize: String

    init(name: String, fullPath: String, type: FileType, size: UInt64, encodingKey: String) {
        self.name = name
        self.fullPath = fullPath
        self.type = type
        self.size = size
        self.encodingKey = encodingKey

        if type == .directory {
            self.formattedSize = "--"
        } else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            self.formattedSize = formatter.string(fromByteCount: Int64(size))
        }
    }

    var id: String { fullPath }

    enum FileType: Sendable {
        case file
        case directory
    }

    var isDirectory: Bool { type == .directory }
}
