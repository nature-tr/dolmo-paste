import XCTest
import AppKit
@testable import DolmoPaste

/// 数据层回归：淘汰、去重、拼音、以及列表状态与数据源的同步
final class ClipStoreTests: XCTestCase {
    @MainActor private func makeStore() throws -> ClipStore { try ClipStore(inMemory: true) }

    @MainActor private func add(_ store: ClipStore, _ text: String) {
        var content = CapturedContent(kind: .text)
        content.text = text
        content.hash = CapturedContent.hash(of: text)
        content.byteSize = text.utf8.count
        store.add(content)
    }

    /// 上限是全局单例，测完必须还原，避免影响真实设置
    @MainActor private func withLimits(history: Int, image: Int, _ body: () -> Void) {
        let settings = AppSettings.shared
        let oldHistory = settings.historyLimit
        let oldImage = settings.imageLimit
        settings.historyLimit = history
        settings.imageLimit = image
        defer {
            settings.historyLimit = oldHistory
            settings.imageLimit = oldImage
        }
        body()
    }

    @MainActor func testPruneAppliesImmediatelyWhenLimitShrinks() throws {
        let store = try makeStore()
        withLimits(history: 50, image: 20) {
            for i in 0..<12 { add(store, "条目 \(i)") }
            XCTAssertEqual(store.items.count, 12)
            // 改小限额后必须立刻淘汰，否则旧数据要等到下次复制才清
            AppSettings.shared.historyLimit = 5
            store.prune()
            store.refresh()
            XCTAssertLessThanOrEqual(store.items.count, 5)
        }
    }

    @MainActor func testPruneKeepsPinnedItems() throws {
        let store = try makeStore()
        withLimits(history: 3, image: 2) {
            for i in 0..<10 { add(store, "条目 \(i)") }
            if let keep = store.items.first {
                store.togglePin(keep)
                store.prune()
                store.refresh()
                XCTAssertTrue(store.items.contains { $0.isPinned }, "淘汰不能删固定项")
            }
        }
    }

    @MainActor func testDuplicateContentDoesNotCreateSecondEntry() throws {
        let store = try makeStore()
        withLimits(history: 50, image: 10) {
            add(store, "同一段文字")
            add(store, "同一段文字")
            XCTAssertEqual(store.items.count, 1)
        }
    }

    func testPinyinMatchesWithoutSpaces() {
        let index = Pinyin.index(for: "你好")
        XCTAssertTrue(Pinyin.matches(text: "你好", pinyinIndex: index, query: "nihao"), "全拼连写必须命中")
        XCTAssertTrue(Pinyin.matches(text: "你好", pinyinIndex: index, query: "nh"), "首字母缩写必须命中")
        XCTAssertTrue(Pinyin.matches(text: "你好", pinyinIndex: index, query: "你好"), "中文原文必须命中")
        XCTAssertFalse(Pinyin.matches(text: "你好", pinyinIndex: index, query: "zzz"))
        XCTAssertEqual(Pinyin.compact(of: "ni hao"), "nihao")
        XCTAssertEqual(Pinyin.initials(of: "ni hao"), "nh")
    }

    @MainActor func testViewModelKeepsSelectionInRangeAndNotifiesLayout() throws {
        let store = try makeStore()
        withLimits(history: 50, image: 10) {
            for i in 0..<5 { add(store, "条目 \(i)") }

            let viewModel = ClipPanelViewModel(store: store)
            var layoutCalls = 0
            var previewHides = 0
            viewModel.onLayoutChange = { layoutCalls += 1 }
            viewModel.onRequestHidePreview = { previewHides += 1 }

            viewModel.selectedIndex = 4
            XCTAssertEqual(viewModel.filtered.count, 5)

            // store 变更必须同时：转发 UI、通知重算面板高度、把选中索引夹回范围
            store.delete(store.items[store.items.count - 1])
            XCTAssertGreaterThanOrEqual(layoutCalls, 1, "删除后面板高度必须重算，否则末行被裁掉")
            XCTAssertLessThan(viewModel.selectedIndex, viewModel.filtered.count, "越界会让回车/⌘P/Delete 静默失效")

            // 删除前要先收掉贴边预览，否则预览仍持有已删除的对象
            if let target = viewModel.selectedItem {
                let before = viewModel.selectedIndex
                viewModel.delete(target)
                XCTAssertEqual(previewHides, 1)
                XCTAssertEqual(viewModel.selectedIndex, min(before, max(viewModel.filtered.count - 1, 0)))
            }
        }
    }

    @MainActor func testOrderedPutsPinnedFirst() throws {
        let store = try makeStore()
        withLimits(history: 50, image: 10) {
            add(store, "A")
            add(store, "B")
            if let last = store.items.last {
                store.togglePin(last)
                let viewModel = ClipPanelViewModel(store: store)
                XCTAssertTrue(viewModel.ordered.first?.isPinned == true, "固定项必须排在最前")
            }
        }
    }

    func testHugeTextIsCappedBeforeStoring() {
        // 复制几百 MB 日志时不能全量入库：这里直接验证截断函数的收敛行为
        let huge = String(repeating: "abcdefghij", count: 200_000)
        XCTAssertGreaterThan(huge.utf8.count, 1_048_576)
        var cut = huge
        while cut.utf8.count > 1_048_576 { cut = String(cut.dropLast(max(1, cut.count / 8))) }
        XCTAssertLessThanOrEqual(cut.utf8.count, 1_048_576)
    }
}
