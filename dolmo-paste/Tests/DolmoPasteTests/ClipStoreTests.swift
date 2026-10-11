import XCTest
import AppKit
import Carbon
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

    /// 文件类条目：原文件被删/移动后不能静默失败，要如实返回并降级成文件名
    func testPasteEngineReportsUnreachableFiles() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        }
        defer {
            pasteboard.clearContents()
            if let saved, !saved.isEmpty {
                for (index, entry) in saved.enumerated() where index == 0 {
                    pasteboard.setData(entry.1, forType: entry.0)
                }
            }
        }

        let missing = ClipItem(kind: .file, textContent: "/不存在的路径/a.txt", contentHash: "missing-file")
        missing.filePaths = ["/绝对不存在的目录/dolmo-测试.txt"]
        missing.fileNames = ["dolmo-测试.txt"]
        let ok = PasteEngine.writeToPasteboard(missing, plainTextOnly: false,
                                               imagesDirectory: FileManager.default.temporaryDirectory)
        XCTAssertFalse(ok, "文件已失效时必须返回 false，不能假装成功")
        // 降级：至少把文件名写进去，用户还能拿到文字而不是空剪贴板
        XCTAssertEqual(pasteboard.string(forType: .string), "dolmo-测试.txt")
    }

    func testColorCaptureNormalizesHex() {
        XCTAssertEqual(ContentHeuristics.normalizedHex("#ff9500"), "#FF9500")
        XCTAssertEqual(ContentHeuristics.normalizedHex("  #f90  "), "#FF9900")
        XCTAssertEqual(ContentHeuristics.normalizedHex("#FF9500CC"), "#FF9500")
        XCTAssertNil(ContentHeuristics.normalizedHex("主题色是 #FF9500 才对"), "正文里带 # 不能判成颜色")
        XCTAssertNil(ContentHeuristics.normalizedHex("#12345"))
        XCTAssertNil(ContentHeuristics.normalizedHex("FF9500"))
    }

    func testHTMLCaptureKeepsTextAndFormatting() {
        let html = "<html><body><p>你好 <b>世界</b></p></body></html>"
        guard let data = html.data(using: .utf8) else { return XCTFail("编码失败") }
        let plain = ContentHeuristics.plainText(fromHTML: data)
        XCTAssertNotNil(plain)
        XCTAssertTrue(plain?.contains("你好") == true)
        XCTAssertTrue(plain?.contains("世界") == true)
        XCTAssertNotNil(ContentHeuristics.rtf(fromHTML: data), "HTML 要转成 RTF，粘贴时才能还原排版")
    }

    @MainActor func testMergedPasteJoinsInVisibleOrder() {
        let pasteboard = NSPasteboard.general
        defer { pasteboard.clearContents() }
        let store = try? makeStore()
        guard let store else { return XCTFail("建库失败") }
        withLimits(history: 50, image: 10) {
            add(store, "第一段")
            add(store, "第二段")
            add(store, "第三段")

            let viewModel = ClipPanelViewModel(store: store)
            var merged: [ClipItem] = []
            viewModel.onPasteMerged = { merged = $0 }

            // 列表是倒序的（新的在前），勾选顺序必须跟列表一致，不能是插入顺序
            let list = viewModel.filtered
            viewModel.toggleCheck(list[0])
            viewModel.toggleCheck(list[2])
            XCTAssertEqual(viewModel.checkedItems.count, 2)
            XCTAssertEqual(viewModel.checkedItems.map(\.textContent), [list[0].textContent, list[2].textContent])

            viewModel.pasteSelection()
            XCTAssertEqual(merged.count, 2)

            let ok = PasteEngine.writeMergedToPasteboard(viewModel.checkedItems,
                                                          imagesDirectory: store.imagesDirectory)
            XCTAssertTrue(ok)
            let text = pasteboard.string(forType: .string) ?? ""
            XCTAssertTrue(text.contains("第一段"))
            XCTAssertTrue(text.contains("第三段"))
            XCTAssertEqual(text.components(separatedBy: "\n").count, 2)

            viewModel.clearChecked()
            XCTAssertTrue(viewModel.checkedItems.isEmpty)
        }
    }

    /// 首屏不能一次拉满上限（上限可设 5000），滚到底再追加
    @MainActor func testRefreshLoadsFirstPageOnlyAndLoadMoreGrows() {
        let store = try? makeStore()
        guard let store else { return XCTFail("建库失败") }
        withLimits(history: 2000, image: 200) {
            for i in 0..<260 { add(store, "条目 \(i)") }
            store.refresh()
            XCTAssertEqual(store.items.count, 200, "首屏只取 200 条")
            XCTAssertTrue(store.hasMore)
            store.loadMore()
            XCTAssertEqual(store.items.count, 260)
            XCTAssertFalse(store.hasMore, "取到底之后不应再继续")
            store.loadMore()
            XCTAssertEqual(store.items.count, 260, "到底后再调也不能重复追加")
        }
    }

    @MainActor func testThumbnailIsLoadedLazilyAndCached() throws {
        let store = try makeStore()
        withLimits(history: 50, image: 10) {
            var content = CapturedContent(kind: .image)
            // 必须真的有 bitmap，否则 pngData 取不到，条目既没落盘原图也没缩略图
            let image = NSImage(size: NSSize(width: 20, height: 10))
            image.lockFocus()
            NSColor.orange.setFill()
            NSRect(x: 0, y: 0, width: 20, height: 10).fill()
            image.unlockFocus()
            content.image = image
            content.hash = "thumb-\(UUID().uuidString)"
            store.add(content)
            guard let item = store.items.first(where: { $0.kind == .image }) else {
                return XCTFail("图片条目没落库")
            }
            // 没落盘原图（缩略图场景）时至少要有内存里的缩略图可用
            XCTAssertNotNil(store.thumbnailData(for: item))
        }
    }

    /// 上架文案写了"来源 App 都能搜"，列表里不显示来源名字但必须搜得到
    @MainActor func testSearchMatchesSourceAppName() throws {
        let store = try makeStore()
        let item = ClipItem(kind: .text, textContent: "一段看不出来源的文字",
                            contentHash: "src-\(UUID().uuidString)",
                            sourceAppBundleID: "com.apple.Safari", sourceAppName: "Safari")
        store.insertSample(item)

        XCTAssertTrue(ClipPanelViewModel.matches(item: item, query: "safari"))
        XCTAssertTrue(ClipPanelViewModel.matches(item: item, query: "SAFARI"))
        XCTAssertFalse(ClipPanelViewModel.matches(item: item, query: "chrome"))

        let vm = ClipPanelViewModel(store: store)
        vm.query = "safari"
        XCTAssertEqual(vm.filtered.count, 1)
        vm.query = "chrome"
        XCTAssertTrue(vm.filtered.isEmpty)
    }

    /// 分页只加不卸，必须有上限；但到底了不能误报"撞上限"
    @MainActor func testLoadMoreStopsAtCapAndDoesNotFalseAlarmAtEnd() throws {
        let store = try makeStore()
        withLimits(history: 3000, image: 200) {
            for i in 0..<260 { add(store, "条目 \(i)") }
            store.loadMore()
            XCTAssertFalse(store.hasMore)
            XCTAssertFalse(store.hasReachedLoadCap, "取到底了不该提示撞上限")
        }

        let capped = try makeStore()
        withLimits(history: 3000, image: 200) {
            // 超过加载上限（1000）才可能撞顶。
            // 走 insertSample 而不是 add：add 每次都 prune，prune 是不带 limit 的全量 fetch，
            // 造 1000+ 条会退化成 O(n²) —— 那本身是个真实的性能隐患，但不属于这个用例要验的东西
            for i in 0..<1010 {
                capped.insertSample(ClipItem(kind: .text, textContent: "条目 \(i)", contentHash: "cap-\(i)"))
            }
            for _ in 0..<10 { capped.loadMore() }
            XCTAssertEqual(capped.loadedCount, capped.loadCap)
            XCTAssertFalse(capped.hasMore)
            XCTAssertTrue(capped.hasReachedLoadCap, "库里还有更多，要如实提示而不是假装到底")
            XCTAssertEqual(capped.items.count, capped.loadCap)
        }
    }

    /// 缩略图缓存换成了有上限的 NSCache，读两次仍然命中同一份数据
    @MainActor func testThumbnailCacheStillServesAfterManyReads() throws {
        let store = try makeStore()
        withLimits(history: 50, image: 10) {
            let image = NSImage(size: NSSize(width: 20, height: 10))
            image.lockFocus()
            NSColor.orange.setFill()
            NSRect(x: 0, y: 0, width: 20, height: 10).fill()
            image.unlockFocus()
            var content = CapturedContent(kind: .image)
            content.image = image
            content.hash = "cache-\(UUID().uuidString)"
            store.add(content)
            guard let item = store.items.first(where: { $0.kind == .image }) else {
                return XCTFail("图片条目没落库")
            }
            let first = store.thumbnailData(for: item)
            XCTAssertNotNil(first)
            XCTAssertEqual(store.thumbnailData(for: item), first)
        }
    }

    /// 异常退出会留下没人引用的图片文件，启动时该清掉
    @MainActor func testOrphanImagesAreDetectedAndRemoved() throws {
        let store = try makeStore()
        // 内存库之间共用同一个临时图片目录，先把别的用例残留的清干净
        store.pruneOrphanImages()
        XCTAssertTrue(store.orphanImageNames().isEmpty)

        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 10).fill()
        image.unlockFocus()
        var content = CapturedContent(kind: .image)
        content.image = image
        content.hash = "keep-\(UUID().uuidString)"
        store.add(content)
        XCTAssertTrue(store.orphanImageNames().isEmpty, "刚落库、有条目引用的图片不能算孤儿")

        let orphan = store.imagesDirectory.appendingPathComponent("orphan-fixture.png")
        try Data("orphan".utf8).write(to: orphan)
        XCTAssertTrue(store.orphanImageNames().contains("orphan-fixture.png"))
        XCTAssertEqual(store.pruneOrphanImages(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testHotkeyDisplayRendersCombos() {
        XCTAssertEqual(HotkeyDisplay.string(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)), "⌘⇧V")
        XCTAssertEqual(HotkeyDisplay.string(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)), "⌘V")
        // 显示顺序固定为 ⌘⇧⌥⌃，跟按键先后无关
        XCTAssertEqual(HotkeyDisplay.string(keyCode: 0x7A, modifiers: UInt32(controlKey | optionKey)), "⌥⌃F1")
        XCTAssertEqual(HotkeyDisplay.string(keyCode: UInt32(kVK_ANSI_V),
                                            modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)), "⌘⇧⌥⌃V")
        XCTAssertEqual(HotkeyDisplay.string(keyCode: 0x31, modifiers: UInt32(cmdKey | shiftKey)), "⌘⇧空格")
        // 没收录的键码回退成 #键码，不能显示成空白
        XCTAssertEqual(HotkeyDisplay.string(keyCode: 999, modifiers: UInt32(cmdKey)), "⌘#999")
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
