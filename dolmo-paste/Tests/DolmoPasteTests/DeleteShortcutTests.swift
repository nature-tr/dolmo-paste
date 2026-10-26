import XCTest
@testable import DolmoPaste

/// 删除快捷键的回归测试。
///
/// 背景：以前的逻辑是「搜索框为空时按裸 ⌫ = 删掉选中条目」。
/// 用户输入错误搜索词后连按退格清空，多按一下就顺手删了一条历史，
/// 而且删完没有撤销入口——所以裸 ⌫ 必须永远不删东西，删除统一走 ⌘⌫。
@MainActor
final class DeleteShortcutTests: XCTestCase {

    private func action(query: String,
                        selection: Bool = true,
                        command: Bool = false,
                        snippet: Bool = false,
                        hinted: Bool = false) -> ClipPanelController.DeleteKeyAction {
        ClipPanelController.deleteKeyAction(
            isSnippetMode: snippet,
            query: query,
            hasSelection: selection,
            hasCommand: command,
            alreadyHinted: hinted)
    }

    /// 核心回归：搜索框已清空，再按一次裸 ⌫，绝对不能删条目
    func testPlainDeleteOnEmptyQueryNeverDeletes() {
        XCTAssertNotEqual(action(query: ""), .deleteItem)
        XCTAssertNotEqual(action(query: "   "), .deleteItem)
    }

    /// 连续退格的完整过程：从有内容到清空，全程没有一步是删除
    func testBackspacingToEmptyNeverDeletes() {
        for q in ["abc", "ab", "a", ""] {
            XCTAssertNotEqual(action(query: q), .deleteItem, "query=\(q) 时不应删除")
        }
    }

    /// 空搜索 + 有选中 + 没提示过 → 提示一次 ⌘⌫
    func testEmptyQueryHintsOnce() {
        XCTAssertEqual(action(query: ""), .hintOnce)
        // 提示过之后就不再打扰，也不再删
        XCTAssertEqual(action(query: "", hinted: true), .passThrough)
    }

    /// 没有选中条目时不该弹提示（列表为空）
    func testNoHintWithoutSelection() {
        XCTAssertEqual(action(query: "", selection: false), .passThrough)
    }

    /// ⌘⌫ 才删除
    func testCommandDeleteDeletes() {
        XCTAssertEqual(action(query: "", command: true), .deleteItem)
        XCTAssertEqual(action(query: "abc", command: true), .deleteItem)
    }

    /// 片段模式一律不删（要删去设置页）
    func testSnippetModeNeverDeletes() {
        XCTAssertEqual(action(query: "", command: true, snippet: true), .passThrough)
        XCTAssertEqual(action(query: "", snippet: true), .passThrough)
    }
}
