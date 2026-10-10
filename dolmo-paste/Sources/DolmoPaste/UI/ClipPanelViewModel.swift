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
    /// 每次唤起自增，用来让搜索框重新聚焦
    @Published var showToken: Int = 0
    /// 按住 ⌘ 时才在前 9 行显示 ⌘1–9，平时不占视觉
    @Published var commandHeld: Bool = false

    private let store: ClipStore
    /// store.items 是数据源，但视图只观察 viewModel——
    /// 必须把 store 的变更转发出去，否则删除/捕获后 UI 不刷新
    private var storeCancellable: AnyCancellable?

    init(store: ClipStore) {
        self.store = store
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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

    /// 把选中索引夹进当前列表范围
    func clampSelection() {
        let count = filtered.count
        guard count > 0 else { selectedIndex = 0; return }
        if selectedIndex >= count { selectedIndex = count - 1 }
        if selectedIndex < 0 { selectedIndex = 0 }
    }

    var storeRef: ClipStore { store }

    /// 展示顺序：Pin 优先，其余按时间倒序
    var ordered: [ClipItem] {
        let pinned = store.items.filter { $0.isPinned }
        let rest = store.items.filter { !$0.isPinned }
        return pinned + rest
    }

    var filtered: [ClipItem] {
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
    }

    var selectedItem: ClipItem? {
        let list = filtered
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    func moveSelection(by delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func selectFirst() { selectedIndex = 0 }

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
        commandHeld = false
        showToken += 1
    }

    func paste(index: Int, plainTextOnly: Bool = false) {
        let list = filtered
        guard index >= 0, index < list.count else { return }
        onPaste?(list[index], plainTextOnly)
    }

    func pasteQuick(_ number: Int, plainTextOnly: Bool = false) {
        paste(index: number - 1, plainTextOnly: plainTextOnly)
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "固定"
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.stack"
        case .pinned: return "pin"
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "doc.on.doc"
        }
    }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return item.isPinned
        case .text: return item.kind == .text
        case .image: return item.kind == .image
        case .file: return item.kind == .file
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
