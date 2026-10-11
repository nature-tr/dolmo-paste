import AppKit
import Combine
import Foundation
import SwiftUI

/// 浮窗的状态与交互逻辑。
/// 排序规则：Pin 的永远在前面，其余按时间倒序；键盘导航走一个扁平数组，简单可靠。
@MainActor
final class ClipPanelViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0
    @Published var filter: ClipFilter = .all
    /// 勾选集合（⌘M）。用于合并粘贴：一次粘出多条内容
    @Published var checkedIDs: Set<UUID> = []
    /// 每次唤起自增，用来让搜索框重新聚焦
    @Published var showToken: Int = 0
    /// 按住 ⌘ 时才在前 9 行显示 ⌘1–9，平时不占视觉
    @Published var commandHeld: Bool = false
    /// 片段模式下的选中行。和历史各用一套索引，切 Tab 时互不带过去
    @Published var snippetIndex: Int = 0

    private let store: ClipStore
    /// store.items 是数据源，但视图只观察 viewModel——
    /// 必须把 store 的变更转发出去，否则删除/捕获后 UI 不刷新
    private var storeCancellable: AnyCancellable?
    private var snippetCancellable: AnyCancellable?

    init(store: ClipStore) {
        self.store = store
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 片段是独立的 store，不会跟着 ClipStore 的通知走。
        // 面板开着时在设置里增删片段，这一路订阅才刷得动
        snippetCancellable = store.snippetStore.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.clampSelection()
            self.objectWillChange.send()
        }
        // 行数变了（捕获/删除/后台淘汰/取消固定）要立刻重算面板高度并夹回选中索引。
        // 必须用"变更之后"的回调：objectWillChange 触发时 items 还是旧值。
        store.onDidChange = { [weak self] in
            guard let self else { return }
            self.clampSelection()
            self.objectWillChange.send()
            self.onLayoutChange?()
        }
    }

    /// 把选中索引夹进当前列表范围。片段模式下夹的是片段索引
    func clampSelection() {
        if isSnippetMode {
            let count = snippetResults.count
            guard count > 0 else { snippetIndex = 0; return }
            if snippetIndex >= count { snippetIndex = count - 1 }
            if snippetIndex < 0 { snippetIndex = 0 }
            return
        }
        let count = filtered.count
        guard count > 0 else { selectedIndex = 0; return }
        if selectedIndex >= count { selectedIndex = count - 1 }
        if selectedIndex < 0 { selectedIndex = 0 }
    }

    var storeRef: ClipStore { store }

    // MARK: 片段模式

    var isSnippetMode: Bool { filter == .snippet }

    /// 片段库还没建好（store 初始化中）时返回空，不能崩
    var snippetResults: [Snippet] {
        store.snippetStore?.search(query) ?? []
    }

    /// 面板高度、键盘边界都按这个行数算：片段模式下是片段条数，否则是历史条数
    var rowCount: Int { isSnippetMode ? snippetResults.count : filtered.count }

    var selectedSnippet: Snippet? {
        let list = snippetResults
        guard snippetIndex >= 0, snippetIndex < list.count else { return nil }
        return list[snippetIndex]
    }

    /// 展示顺序：Pin 优先，其余按时间倒序
    var ordered: [ClipItem] {
        let pinned = store.items.filter { $0.isPinned }
        let rest = store.items.filter { !$0.isPinned }
        return pinned + rest
    }

    var filtered: [ClipItem] {
        // 片段模式下列表里没有历史项，别让 filter.matches 意外漏进来
        guard !isSnippetMode else { return [] }
        let base = ordered.filter { filter.matches($0) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter { Self.matches(item: $0, query: q) }
    }

    /// Tab 键循环切类型
    func cycleFilter() {
        let all = ClipFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        filter = all[(index + 1) % all.count]
        selectedIndex = 0
        snippetIndex = 0
    }

    var selectedItem: ClipItem? {
        let list = filtered
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    func moveSelection(by delta: Int) {
        if isSnippetMode {
            let count = snippetResults.count
            guard count > 0 else { return }
            snippetIndex = min(max(snippetIndex + delta, 0), count - 1)
            return
        }
        let count = filtered.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func selectFirst() { selectedIndex = 0; snippetIndex = 0 }

    // MARK: 勾选（合并粘贴）

    func isChecked(_ item: ClipItem) -> Bool { checkedIDs.contains(item.id) }

    /// 勾选 / 取消某一行
    func toggleCheck(_ item: ClipItem) {
        if checkedIDs.contains(item.id) {
            checkedIDs.remove(item.id)
        } else {
            checkedIDs.insert(item.id)
        }
    }

    func toggleCheckAt(index: Int) {
        let list = filtered
        guard list.indices.contains(index) else { return }
        toggleCheck(list[index])
    }

    /// ⌘M：勾选当前行并下移，方便连续勾
    func toggleCheckAtSelection() {
        guard let item = selectedItem else { return }
        toggleCheck(item)
        moveSelection(by: 1)
    }

    func clearChecked() { checkedIDs.removeAll() }

    /// 勾选项（保持列表里的可见顺序），没勾就退回当前行
    var checkedItems: [ClipItem] {
        guard !checkedIDs.isEmpty else { return [] }
        return filtered.filter { checkedIDs.contains($0.id) }
    }

    /// 删除一条并保留原来的位置（不跳回首行）。
    /// 删除前必须先收掉贴边预览：预览还持有这条数据，item 被 delete 后读属性会残留甚至异常。
    func delete(_ item: ClipItem) {
        let index = selectedIndex
        onRequestHidePreview?()
        store.delete(item)
        selectedIndex = index
        clampSelection()
    }

    /// 删除前用它关掉贴边预览（由控制器注入，ViewModel 不直接依赖 UI）
    var onRequestHidePreview: (() -> Void)?

    /// 由面板控制器注入，避免 ViewModel 反向依赖 UI 层
    var onPaste: ((ClipItem, Bool) -> Void)?
    /// 合并粘贴：把勾选项按顺序拼好一次粘出
    var onPasteMerged: (([ClipItem]) -> Void)?
    /// 粘出片段（控制器负责展开变量、写剪贴板、模拟 ⌘V）
    var onPasteSnippet: ((Snippet) -> Void)?
    /// 从片段行跳到设置页的片段管理
    var onOpenSnippetSettings: (() -> Void)?
    var onRequestClose: (() -> Void)?
    /// 打开大图查看器（→ 键和右键菜单共用）
    var onOpenImageViewer: ((ClipItem) -> Void)?
    /// hover 到图片行 / 离开图片行，交给控制器驱动贴边预览
    var onHoverImage: ((ClipItem, Bool) -> Void)?
    /// 过滤/搜索导致列表高度变化时通知控制器重算面板尺寸
    var onLayoutChange: (() -> Void)?

    func reset() {
        query = ""
        filter = .all
        selectedIndex = 0
        snippetIndex = 0
        // 每次唤起都是全新一轮，上一轮的勾选不能带过来
        checkedIDs.removeAll()
        commandHeld = false
        showToken += 1
    }

    func paste(index: Int, plainTextOnly: Bool = false) {
        let list = filtered
        guard index >= 0, index < list.count else { return }
        onPaste?(list[index], plainTextOnly)
    }

    func pasteQuick(_ number: Int, plainTextOnly: Bool = false) {
        if isSnippetMode { pasteSnippet(at: number - 1); return }
        paste(index: number - 1, plainTextOnly: plainTextOnly)
    }

    /// 粘出片段（点击 / 回车）
    func pasteSnippet(at index: Int) {
        let list = snippetResults
        guard list.indices.contains(index) else { return }
        onPasteSnippet?(list[index])
    }

    /// 回车：片段模式粘片段；有勾选就合并粘贴，否则粘当前行
    func pasteSelection(plainTextOnly: Bool = false) {
        if isSnippetMode {
            guard let snippet = selectedSnippet else { return }
            onPasteSnippet?(snippet)
            return
        }
        let checked = checkedItems
        if checked.count > 1 {
            onPasteMerged?(checked)
        } else if let item = checked.first ?? selectedItem {
            onPaste?(item, plainTextOnly)
        }
    }

    static func matches(item: ClipItem, query: String) -> Bool {
        let q = query.lowercased()
        if item.textContent.localizedCaseInsensitiveContains(q) { return true }
        if !item.fileNames.isEmpty, item.fileNames.joined(separator: " ").localizedCaseInsensitiveContains(q) { return true }
        let ocr = item.ocrRecognizedText
        if !ocr.isEmpty, ocr.localizedCaseInsensitiveContains(q) { return true }
        if let pinyin = item.pinyinIndex, !pinyin.isEmpty {
            if pinyin.contains(q) { return true }
            // 用户输入 "nihao"，索引是 "ni hao"，去空格后再比一次
            if Pinyin.compact(of: pinyin).contains(q) { return true }
            if Pinyin.initials(of: pinyin).contains(q) { return true }
        }
        return false
    }
}

/// 类型过滤分栏
enum ClipFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case image
    case file
    /// 不是历史的一种类型，是另一个数据源（常用片段）。放在最后，Tab 兜一圈才到
    case snippet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "固定"
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        case .snippet: return "片段"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.stack"
        case .pinned: return "pin"
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "doc.on.doc"
        case .snippet: return "doc.text.magnifyingglass"
        }
    }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return item.isPinned
        case .text: return item.kind == .text
        case .image: return item.kind == .image
        case .file: return item.kind == .file
        case .snippet: return false
        }
    }
}

enum TimeFormat {
    static func relative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 7 * 86400 { return "\(Int(interval / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}
