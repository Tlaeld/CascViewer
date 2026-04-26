import Foundation

struct CASCFileEntry: Identifiable, Hashable, Sendable {
    let name: String
    let fullPath: String
    let type: FileType
    let size: UInt64
    let encodingKey: String

    var id: String { fullPath }

    enum FileType: Sendable {
        case file
        case directory
    }

    var isDirectory: Bool { type == .directory }
    var formattedSize: String {
        guard type == .file else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
