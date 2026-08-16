import Foundation

/// 主窗口侧栏目录树的展开状态。
///
/// 展开状态在内存导航(CASCStorageService.navigate)下保持不变,
/// 只有在存储条目真正重载(entriesGeneration 变化)时由视图层调用 reset() 清空。
/// 这修复了"点开一个目录、另一个目录自动收起"的 bug。
@MainActor
final class TreeExpansionStore: ObservableObject {
    @Published private(set) var expandedPaths: Set<String> = []

    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func toggle(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
    }

    func expand(_ path: String) {
        expandedPaths.insert(path)
    }

    func collapse(_ path: String) {
        expandedPaths.remove(path)
    }

    /// 展开 path 本身及其全部祖先目录(复刻旧代码导航时自动展开祖先链的行为,
    /// 但不再清空其他分支)。
    func expandAncestors(of path: String) {
        var p = path
        while !p.isEmpty {
            expandedPaths.insert(p)
            p = (p as NSString).deletingLastPathComponent
        }
    }

    func reset() {
        expandedPaths.removeAll()
    }
}
