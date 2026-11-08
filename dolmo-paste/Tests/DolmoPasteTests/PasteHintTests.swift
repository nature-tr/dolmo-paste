import XCTest
@testable import DolmoPaste

/// 自动粘贴提示文案的回归测试。
///
/// 背景：这个 App 有两种粘贴行为——拿到辅助功能授权时「选中即粘」，
/// 没授权时「只进剪贴板，用户按 ⌘V」。两者共用同一批提示文案，
/// 判断写反就会出现两种很蠢的现象：
///   1. 自动粘贴明明生效了，还弹一句「按 ⌘V 粘贴」
///   2. 「去哪儿开启」这句话每粘一次念一遍，变成骚扰
/// 所以把文案分支抽成纯函数钉在这里。

final class PasteHintTests: XCTestCase {

    func testFirstTimeMentionsWhereToEnable() {
        let text = PasteEngine.manualPasteHint("已复制，按 ⌘V 粘贴", alreadyShown: false)
        XCTAssertTrue(text.contains("设置"), "第一次必须告诉用户去哪儿开启，否则这个功能永远没人发现")
        XCTAssertTrue(text.contains("按 ⌘V"), "原提示不能被吞掉——用户此刻仍然需要知道怎么粘")
    }

    func testAfterFirstTimeStaysShort() {
        let base = "已复制，按 ⌘V 粘贴"
        let text = PasteEngine.manualPasteHint(base, alreadyShown: true)
        XCTAssertEqual(text, base, "已经说过一次就不该再啰嗦")
        XCTAssertFalse(text.contains("设置"))
    }

    func testHintNeverEmpty() {
        for base in ["已复制，按 ⌘V 粘贴", "已复制 3 条，按 ⌘V 粘贴", "已复制片段，按 ⌘V 粘贴"] {
            XCTAssertFalse(PasteEngine.manualPasteHint(base, alreadyShown: false).isEmpty)
            XCTAssertFalse(PasteEngine.manualPasteHint(base, alreadyShown: true).isEmpty)
        }
    }

    /// 合并多条时的提示只在「没授权」这条路上出现，
    /// 因为自动粘贴成功时不该有提示。这里锁住条数确实进得去。
    func testMergedCountSurvives() {
        let base = "已复制 3 条，按 ⌘V 粘贴"
        XCTAssertEqual(PasteEngine.manualPasteHint(base, alreadyShown: true), base)
        XCTAssertTrue(PasteEngine.manualPasteHint(base, alreadyShown: false).hasPrefix(base),
                      "追加的说明只能加在末尾，不能把原句改掉")
    }
}
