import XCTest
@testable import CascViewer

@MainActor
final class TreeExpansionStoreTests: XCTestCase {

    func testToggleExpandsAndCollapses() {
        let store = TreeExpansionStore()
        XCTAssertFalse(store.isExpanded("mods"))
        store.toggle("mods")
        XCTAssertTrue(store.isExpanded("mods"))
        store.toggle("mods")
        XCTAssertFalse(store.isExpanded("mods"))
    }

    func testExpandAndCollapseAreIdempotent() {
        let store = TreeExpansionStore()
        store.expand("a")
        store.expand("a")
        XCTAssertEqual(store.expandedPaths, ["a"])
        store.collapse("a")
        store.collapse("a")
        XCTAssertTrue(store.expandedPaths.isEmpty)
    }

    func testExpandAncestorsExpandsWholeChain() {
        let store = TreeExpansionStore()
        store.expandAncestors(of: "mods/heroes.stormmod/base.stormassets")
        XCTAssertEqual(store.expandedPaths, [
            "mods",
            "mods/heroes.stormmod",
            "mods/heroes.stormmod/base.stormassets",
        ])
    }

    func testExpandAncestorsOfRootDoesNothing() {
        let store = TreeExpansionStore()
        store.expandAncestors(of: "")
        XCTAssertTrue(store.expandedPaths.isEmpty)
    }

    func testResetClearsExpansion() {
        let store = TreeExpansionStore()
        store.expandAncestors(of: "a/b/c")
        XCTAssertFalse(store.expandedPaths.isEmpty)
        store.reset()
        XCTAssertTrue(store.expandedPaths.isEmpty)
    }

    func testSiblingBranchesSurviveAncestorExpansion() {
        // 回归测试:展开某条路径的祖先链,不得清掉别处已展开的分支(旧的自动收起 bug)。
        let store = TreeExpansionStore()
        store.toggle("mods")
        store.toggle("mods/core.stormmod")
        store.expandAncestors(of: "campaigns/liberty.sc2campaign")
        XCTAssertTrue(store.isExpanded("mods"))
        XCTAssertTrue(store.isExpanded("mods/core.stormmod"))
        XCTAssertTrue(store.isExpanded("campaigns"))
        XCTAssertTrue(store.isExpanded("campaigns/liberty.sc2campaign"))
    }
}
