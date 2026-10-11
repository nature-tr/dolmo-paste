import XCTest
import AppKit
@testable import DolmoPaste

/// 片段（Snippets）回归：变量展开、增删改查、以及浮窗里的片段模式
final class SnippetTests: XCTestCase {

    @MainActor private func makeStore() throws -> ClipStore { try ClipStore(inMemory: true) }

    // MARK: 变量展开

    func testExpanderLeavesPlainContentAlone() {
        // 没有 {{ 就原样返回，连 DateFormatter 都不该建
        XCTAssertEqual(SnippetExpander.expand("hello"), "hello")
        XCTAssertEqual(SnippetExpander.expand(""), "")
    }

    func testExpanderReplacesAllSupportedVariables() {
        let content = SnippetExpander.supportedVariables.joined(separator: " ")
        let result = SnippetExpander.expand(content, clipboard: "剪切板内容")
        // 支持列表里的变量必须全部被吃掉，不能留一个 {{ 在粘出去的文本里
        XCTAssertFalse(result.contains("{{"), "还有没展开的变量：\(result)")
        XCTAssertFalse(result.contains("}}"), "还有没展开的变量：\(result)")
        XCTAssertTrue(result.contains("剪切板内容"))
    }

    func testExpanderUsesClipboardOnlyWhenProvided() {
        // 没传剪贴板时 {{clipboard}} 要留着，不能替换成空串——
        // 粘出去少一段比多一段 {{clipboard}} 更难发现
        XCTAssertEqual(SnippetExpander.expand("a{{clipboard}}b"), "a{{clipboard}}b")
        XCTAssertEqual(SnippetExpander.expand("a{{clipboard}}b", clipboard: "X"), "aXb")
    }

    func testExpanderKeepsUnknownVariables() {
        XCTAssertEqual(SnippetExpander.expand("{{nope}}"), "{{nope}}")
    }

    func testExpanderDateLooksLikeADate() {
        let result = SnippetExpander.expand("{{date}}")
        // yyyy-MM-dd
        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.filter { $0 == "-" }.count, 2)
        XCTAssertNotNil(Int(result.replacingOccurrences(of: "-", with: "")))
    }

    // MARK: 片段库

    @MainActor func testAddUpdateDelete() throws {
        let store = try makeStore()
        let snippets = store.snippetStore!
        XCTAssertTrue(snippets.snippets.isEmpty)

        let s = snippets.add(title: "邮箱", content: "a@b.com", keyword: "mail")
        XCTAssertEqual(snippets.snippets.count, 1)
        XCTAssertEqual(s.displayTitle, "邮箱")

        snippets.update(s, title: "工作邮箱", content: "c@d.com", keyword: "work")
        XCTAssertEqual(snippets.snippets.first?.displayTitle, "工作邮箱")
        XCTAssertEqual(snippets.snippets.first?.content, "c@d.com")

        snippets.delete(s)
        XCTAssertTrue(snippets.snippets.isEmpty)
    }

    @MainActor func testDisplayTitleFallsBackToContent() throws {
        let store = try makeStore()
        let snippets = store.snippetStore!
        let s = snippets.add(title: "   ", content: "第一行\n第二行", keyword: "")
        XCTAssertEqual(s.displayTitle, "第一行")
        let empty = snippets.add(title: "", content: "", keyword: "")
        XCTAssertEqual(empty.displayTitle, "未命名片段")
    }

    @MainActor func testMarkUsedCountsAndTimestamps() throws {
        let store = try makeStore()
        let snippets = store.snippetStore!
        let s = snippets.add(title: "签名", content: "此致", keyword: "sig")
        XCTAssertEqual(s.useCount, 0)
        XCTAssertNil(s.lastUsedAt)

        snippets.markUsed(s)
        snippets.markUsed(s)
        let first = snippets.snippets.first { $0.id == s.id }
        XCTAssertEqual(first?.useCount, 2)
        XCTAssertNotNil(first?.lastUsedAt)
    }

    @MainActor func testSearchHitsTitleContentAndKeyword() throws {
        let store = try makeStore()
        let snippets = store.snippetStore!
        _ = snippets.add(title: "收货地址", content: "深圳市南山区", keyword: "addr")
        _ = snippets.add(title: "签名", content: "此致敬礼", keyword: "sig")

        XCTAssertEqual(snippets.search("签名").count, 1)
        XCTAssertEqual(snippets.search("南山").count, 1)      // 内容命中
        XCTAssertEqual(snippets.search("addr").count, 1)      // 触发词命中
        XCTAssertEqual(snippets.search("ADDR").count, 1)      // 大小写不敏感
        XCTAssertEqual(snippets.search("  ").count, 2)        // 空白视为没输
        XCTAssertEqual(snippets.search("没有的").count, 0)
    }

    /// 片段和历史同一张库，但互不影响
    @MainActor func testSnippetsAreIndependentFromHistory() throws {
        let store = try makeStore()
        _ = store.snippetStore!.add(title: "片段", content: "内容", keyword: "")
        var content = CapturedContent(kind: .text)
        content.text = "历史条目"
        content.hash = CapturedContent.hash(of: "历史条目")
        store.add(content)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.snippetStore!.snippets.count, 1)

        store.clearAll(includePinned: true)
        XCTAssertEqual(store.items.count, 0)
        // 清历史不能把片段一起清掉
        XCTAssertEqual(store.snippetStore!.snippets.count, 1)
    }

    // MARK: 浮窗的片段模式

    @MainActor func testSnippetModeSwitchesDataSource() throws {
        let store = try makeStore()
        let snippets = store.snippetStore!
        _ = snippets.add(title: "邮箱", content: "a@b.com", keyword: "mail")
        _ = snippets.add(title: "签名", content: "此致", keyword: "sig")

        var content = CapturedContent(kind: .text)
        content.text = "一条历史"
        content.hash = CapturedContent.hash(of: "一条历史")
        store.add(content)

        let vm = ClipPanelViewModel(store: store)
        XCTAssertFalse(vm.isSnippetMode)
        XCTAssertEqual(vm.rowCount, 1)

        vm.filter = .snippet
        XCTAssertTrue(vm.isSnippetMode)
        // 片段模式下行数按片段算，历史一条都不能混进来
        XCTAssertEqual(vm.rowCount, 2)
        XCTAssertTrue(vm.filtered.isEmpty)

        // 片段按创建时间倒序（新的在上面），和历史一致
        XCTAssertEqual(Set(vm.snippetResults.map(\.displayTitle)), ["邮箱", "签名"])
        vm.moveSelection(by: 1)
        XCTAssertEqual(vm.snippetIndex, 1)
        XCTAssertNotNil(vm.selectedSnippet)
        // 边界：不能越界
        vm.moveSelection(by: 10)
        XCTAssertEqual(vm.snippetIndex, 1)
        vm.moveSelection(by: -10)
        XCTAssertEqual(vm.snippetIndex, 0)
    }

    @MainActor func testSnippetModeSearchAndPaste() throws {
        let store = try makeStore()
        let snippets = store.snippetStore!
        _ = snippets.add(title: "邮箱", content: "a@b.com", keyword: "mail")
        _ = snippets.add(title: "签名", content: "此致敬礼", keyword: "sig")

        let vm = ClipPanelViewModel(store: store)
        vm.filter = .snippet

        vm.query = "sig"
        XCTAssertEqual(vm.rowCount, 1)
        XCTAssertEqual(vm.selectedSnippet?.displayTitle, "签名")

        var pasted: String?
        vm.onPasteSnippet = { pasted = $0.content }
        vm.pasteSelection()
        XCTAssertEqual(pasted, "此致敬礼")

        // 搜不到的时候回车不能崩，也不能粘出上一条
        vm.query = "不存在"
        pasted = nil
        vm.pasteSelection()
        XCTAssertNil(pasted)
    }

    /// Tab 循环要能走到片段，且每次切换都把两套选中索引归零
    @MainActor func testFilterCycleReachesSnippets() throws {
        let store = try makeStore()
        let vm = ClipPanelViewModel(store: store)
        XCTAssertTrue(ClipFilter.allCases.contains(.snippet))

        var seen: [ClipFilter] = []
        for _ in 0..<ClipFilter.allCases.count {
            seen.append(vm.filter)
            vm.selectedIndex = 3
            vm.snippetIndex = 2
            vm.cycleFilter()
        }
        XCTAssertEqual(seen.count, ClipFilter.allCases.count)
        XCTAssertTrue(seen.contains(.snippet))
        XCTAssertEqual(seen.first, .all)
        XCTAssertEqual(vm.selectedIndex, 0)
        XCTAssertEqual(vm.snippetIndex, 0)
    }

    /// 唤起时重置：上一轮的片段选中不能带过来
    @MainActor func testResetClearsSnippetSelection() throws {
        let store = try makeStore()
        let vm = ClipPanelViewModel(store: store)
        vm.filter = .snippet
        vm.snippetIndex = 3
        vm.query = "abc"
        vm.reset()
        XCTAssertEqual(vm.filter, .all)
        XCTAssertEqual(vm.snippetIndex, 0)
        XCTAssertTrue(vm.query.isEmpty)
    }
}
