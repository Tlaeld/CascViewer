import XCTest
@testable import CascViewer

final class ChildrenMapTests: XCTestCase {

    // MARK: - buildChildrenMap

    func testBuildChildrenMapBasicStructure() {
        let entries = [
            CASCFileEntry(name: "file1.txt", fullPath: "root/dir1/file1.txt", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "file2.txt", fullPath: "root/dir1/file2.txt", type: .file, size: 200, encodingKey: ""),
            CASCFileEntry(name: "file3.txt", fullPath: "root/dir2/file3.txt", type: .file, size: 300, encodingKey: "")
        ]

        let (childrenMap, entriesByPath) = CASCStorageService.buildChildrenMap(from: entries)

        // Root should have "root" directory
        XCTAssertEqual(childrenMap[""]?.count, 1)
        XCTAssertTrue(childrenMap[""]?.contains(where: { $0.name == "root" }) ?? false)

        // "root" should have "dir1" and "dir2"
        XCTAssertEqual(childrenMap["root"]?.count, 2)

        // "root/dir1" should have 2 files
        XCTAssertEqual(childrenMap["root/dir1"]?.count, 2)
        XCTAssertTrue(childrenMap["root/dir1"]?.contains(where: { $0.name == "file1.txt" }) ?? false)

        // entriesByPath should contain all files
        XCTAssertEqual(entriesByPath.count, 3)
        XCTAssertNotNil(entriesByPath["root/dir1/file1.txt"])
    }

    func testBuildChildrenMapVirtualDirectories() {
        let entries = [
            CASCFileEntry(name: "abc123", fullPath: "abc123", type: .file, size: 100, encodingKey: "", nameType: .ckey),
            CASCFileEntry(name: "def456", fullPath: "def456", type: .file, size: 200, encodingKey: "", nameType: .ekey),
            CASCFileEntry(name: "real.txt", fullPath: "real.txt", type: .file, size: 50, encodingKey: "")
        ]

        let (childrenMap, _) = CASCStorageService.buildChildrenMap(from: entries)

        // Root should have CONTENT_KEY, ENCODED_KEY, and real.txt
        XCTAssertEqual(childrenMap[""]?.count, 3)
        XCTAssertTrue(childrenMap[""]?.contains(where: { $0.name == "CONTENT_KEY" }) ?? false)
        XCTAssertTrue(childrenMap[""]?.contains(where: { $0.name == "ENCODED_KEY" }) ?? false)
        XCTAssertTrue(childrenMap[""]?.contains(where: { $0.name == "real.txt" }) ?? false)

        // Virtual directories should have their entries
        XCTAssertEqual(childrenMap["CONTENT_KEY"]?.count, 1)
        XCTAssertEqual(childrenMap["ENCODED_KEY"]?.count, 1)
    }

    func testBuildChildrenMapEmpty() {
        let (childrenMap, entriesByPath) = CASCStorageService.buildChildrenMap(from: [])
        XCTAssertTrue(childrenMap.isEmpty)
        XCTAssertTrue(entriesByPath.isEmpty)
    }

    func testBuildChildrenMapDeepNesting() {
        let entries = [
            CASCFileEntry(name: "deep.txt", fullPath: "a/b/c/d/deep.txt", type: .file, size: 10, encodingKey: "")
        ]

        let (childrenMap, _) = CASCStorageService.buildChildrenMap(from: entries)

        XCTAssertEqual(childrenMap[""]?.count, 1)
        XCTAssertEqual(childrenMap["a"]?.count, 1)
        XCTAssertEqual(childrenMap["a/b"]?.count, 1)
        XCTAssertEqual(childrenMap["a/b/c"]?.count, 1)
        XCTAssertEqual(childrenMap["a/b/c/d"]?.count, 1)
    }

    func testBuildChildrenMapIsLocalPropagation() {
        let entries = [
            CASCFileEntry(name: "local.txt", fullPath: "dir/local.txt", type: .file, size: 10, encodingKey: "", isLocal: true),
            CASCFileEntry(name: "remote.txt", fullPath: "dir/remote.txt", type: .file, size: 10, encodingKey: "", isLocal: false)
        ]

        let (childrenMap, _) = CASCStorageService.buildChildrenMap(from: entries)

        // "dir" should be marked local because it contains a local file
        let dirNode = childrenMap[""]?.first(where: { $0.name == "dir" })
        XCTAssertEqual(dirNode?.isLocal, true)

        // File nodes should preserve their isLocal flag
        let localFile = childrenMap["dir"]?.first(where: { $0.name == "local.txt" })
        XCTAssertEqual(localFile?.isLocal, true)

        let remoteFile = childrenMap["dir"]?.first(where: { $0.name == "remote.txt" })
        XCTAssertEqual(remoteFile?.isLocal, false)
    }

    func testBuildChildrenMapFileAndDirNameCollision() {
        // If a directory name matches a file name in the same parent,
        // the directory should take precedence
        let entries = [
            CASCFileEntry(name: "conflict.txt", fullPath: "conflict.txt", type: .file, size: 10, encodingKey: ""),
            CASCFileEntry(name: "inner.txt", fullPath: "conflict.txt/inner.txt", type: .file, size: 20, encodingKey: "")
        ]

        let (childrenMap, _) = CASCStorageService.buildChildrenMap(from: entries)

        // Root should have the directory "conflict.txt"
        let rootChildren = childrenMap[""] ?? []
        let conflictNodes = rootChildren.filter { $0.name == "conflict.txt" }
        XCTAssertEqual(conflictNodes.count, 1)
        XCTAssertNotNil(conflictNodes.first?.children)
    }

    // MARK: - computeChildren

    func testComputeChildrenBasic() {
        let entries = [
            CASCFileEntry(name: "file1.txt", fullPath: "root/file1.txt", type: .file, size: 100, encodingKey: ""),
            CASCFileEntry(name: "subdir", fullPath: "root/subdir/file2.txt", type: .file, size: 200, encodingKey: "")
        ]

        let children = CASCStorageService.computeChildren(for: "root", from: entries)
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children.contains(where: { $0.name == "file1.txt" && $0.children == nil }))
        XCTAssertTrue(children.contains(where: { $0.name == "subdir" && $0.children == nil }))
    }

    func testComputeChildrenEmptyPath() {
        let entries = [
            CASCFileEntry(name: "top.txt", fullPath: "top.txt", type: .file, size: 100, encodingKey: "")
        ]

        let children = CASCStorageService.computeChildren(for: "", from: entries)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.name, "top.txt")
    }

    func testComputeChildrenNoMatches() {
        let entries = [
            CASCFileEntry(name: "file.txt", fullPath: "other/file.txt", type: .file, size: 100, encodingKey: "")
        ]

        let children = CASCStorageService.computeChildren(for: "nonexistent", from: entries)
        XCTAssertTrue(children.isEmpty)
    }
}
