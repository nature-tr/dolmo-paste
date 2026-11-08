import AppKit
import Carbon
import SwiftUI

/// 能被键盘聚焦但不激活 App 的面板。
/// 这是整个交互的地基：不激活，原 App 就保留焦点，⌘V 才能落到它身上。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 面板是 nonactivating 的：⌘A 这类编辑命令不会被 AppKit 自动派发给搜索框，
    /// 这里显式接住，转发给当前的 field editor。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let chars = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        let selectors: [Character: Selector] = [
            "a": #selector(NSTextView.selectAll(_:)),
            "x": #selector(NSTextView.cut(_:)),
            "c": #selector(NSTextView.copy(_:)),
            "v": #selector(NSTextView.paste(_:)),
            "z": Selector(("undo:")),
        ]
        guard let selector = selectors[chars.lowercased().first ?? " "],
              let responder = firstResponder,
              responder.responds(to: selector) else { return super.performKeyEquivalent(with: event) }
        responder.doCommand(by: selector)
        return true
    }
}

@MainActor
final class ClipPanelController {
    private let store: ClipStore
    private let monitor: ClipboardMonitor
    private let viewModel: ClipPanelViewModel
    private let panel: KeyablePanel
    private var hosting: NSHostingView<ClipPanelView>!
    private var preview: ImagePreviewController!

    private var eventMonitor: Any?
    private var previousApp: NSRunningApplication?
    /// 每次唤起只提示一次「⌘⌫ 删除」，避免连按退格时提示刷屏
    private var didHintDeleteShortcut = false

    /// 打开设置，并直接落到指定分区（片段行上右键会跳到「片段」）
    var onOpenSettings: ((SettingsSection) -> Void)?
    /// 打开大图查看器。带出 previousApp，查看器关掉后焦点还回原 App
    var onOpenImageViewer: ((ClipItem, NSRunningApplication?) -> Void)?

    private var theme: PanelTheme { PanelTheme.theme(for: AppSettings.shared.panelStyle) }

    init(store: ClipStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        self.viewModel = ClipPanelViewModel(store: store)

        let initialTheme = PanelTheme.theme(for: AppSettings.shared.panelStyle)
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initialTheme.panelWidth, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false

        hosting = NSHostingView(rootView: ClipPanelView(viewModel: viewModel, theme: initialTheme))
        panel.contentView = hosting

        viewModel.onPaste = { [weak self] item, plain in
            self?.pasteItem(item, plainTextOnly: plain)
        }
        viewModel.onPasteMerged = { [weak self] items in
            self?.pasteMerged(items)
        }
        viewModel.onPasteSnippet = { [weak self] snippet in
            self?.pasteSnippet(snippet)
        }
        viewModel.onOpenSnippetSettings = { [weak self] in
            guard let self else { return }
            self.hide(returnFocus: false)
            self.onOpenSettings?(.snippets)
        }
        viewModel.onRequestClose = { [weak self] in self?.hide() }
        viewModel.onOpenImageViewer = { [weak self] item in self?.openImageViewer(for: item) }
        viewModel.onHoverImage = { [weak self] item, hovering in
            guard let self else { return }
            if hovering {
                preview.scheduleShow(item, imagesDirectory: store.imagesDirectory)
            } else {
                preview.endHover(item)
            }
        }
        viewModel.onLayoutChange = { [weak self] in self?.resize() }
        viewModel.onRequestHidePreview = { [weak self] in self?.preview.hide() }

        preview = ImagePreviewController(theme: initialTheme)
        preview.anchorWindow = panel
        preview.onResignKey = { [weak self] in self?.panelDidResignKey() }
        preview.onClosePreview = { [weak self] in self?.panel.makeKey() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        // 面板可拖动，拖动时预览要跟着走
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        viewModel.reset()
        didHintDeleteShortcut = false
        preview.hide()

        // 样式可能刚被改过，每次唤起都重挂一遍
        let currentTheme = theme
        hosting.rootView = ClipPanelView(viewModel: viewModel, theme: currentTheme)
        preview.updateTheme(currentTheme)

        resize()
        // 面板贴着鼠标弹出。以前是贴输入光标，靠 AX 读焦点控件的位置，
        // 但那属于「把辅助功能用于非无障碍用途」，App Store 明确不接受（2.4.5），
        // 所以现在只用鼠标位置——鼠标在哪，人就还在哪，注意力一样不用跑远
        position(near: NSEvent.mouseLocation)
        panel.makeKeyAndOrderFront(nil)
        applySelectionColor(for: currentTheme)
        installEventMonitor()
    }

    func hide(returnFocus: Bool = true) {
        guard isVisible else { return }
        removeEventMonitor()
        preview.hide()
        panel.orderOut(nil)
        panel.resignKey()

        // 焦点还给原来的 App，否则 ⌘V 无处可去；
        // 打开设置等场景传 false，避免原 App 抢走刚要弹出的窗口
        if returnFocus, let app = previousApp, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate()
        }
        previousApp = nil
    }

    /// 搜索框选中文字的底色：dolmo 用橙 30%，系统样式还原成系统选中色
    private func applySelectionColor(for theme: PanelTheme) {
        guard let editor = panel.fieldEditor(true, for: nil) as? NSTextView else { return }
        let background: NSColor = theme.kind == .dolmo
            ? NSColor(hex: 0xFFA639, alpha: 0.3)
            : .selectedTextBackgroundColor
        editor.selectedTextAttributes = [.backgroundColor: background]
    }

    // MARK: - 尺寸与定位

    private func resize() {
        let currentTheme = theme
        let height = currentTheme.panelHeight(rowCount: viewModel.rowCount)
        panel.setContentSize(NSSize(width: currentTheme.panelWidth, height: height))
        hosting.frame = NSRect(x: 0, y: 0, width: currentTheme.panelWidth, height: height)
        preview.reposition()
    }

    @objc private func panelDidMove() {
        preview.reposition()
    }

    private func position(near point: CGPoint?) {
        let anchor = point ?? NSEvent.mouseLocation
        let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size

        var x = anchor.x - 40
        var y = anchor.y - size.height - 8

        // 下方空间不够就翻到上方
        if y < visible.minY {
            y = anchor.y + 24
        }
        x = min(max(x, visible.minX + 8), max(visible.maxX - size.width - 8, visible.minX + 8))
        y = min(max(y, visible.minY + 8), max(visible.maxY - size.height - 8, visible.minY + 8))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 键盘

    private func installEventMonitor() {
        removeEventMonitor()
        // 滚轮 / 捏合也要监听：鼠标在贴边预览上时要交给预览做缩放
        // mouseMoved 也要监听：鼠标移到预览上时把 key 交给它，
        // 不然捏合/滚轮会派发给前台别的 App，预览收不到手势
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel, .magnify, .mouseMoved]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved {
                self.preview.takeKeyIfMouseInside()
                return event
            }
            guard event.window === self.panel || self.preview.owns(event) else { return event }
            if event.type == .flagsChanged {
                // 只按 ⌘（不带 ⇧⌥⌃）才亮序号，避免 ⌘⇧ 之类的组合键闪一下
                let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let held = flags == .command
                if self.viewModel.commandHeld != held { self.viewModel.commandHeld = held }
                return event
            }
            if event.type == .keyDown {
                let fromPreview = self.preview.owns(event)
                if fromPreview { self.panel.makeKey() }
                if self.handle(event) { return nil }
                // 换 key 不会改变现有事件的窗口归属。交 field editor 的输入法路径，不能 insertText 绕过中文组词。
                if fromPreview, let editor = self.panel.firstResponder as? NSTextView {
                    editor.interpretKeyEvents([event])
                    return nil
                }
                return event
            }
            return self.preview.consume(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    /// 把 ⌘A / ⌘X / ⌘C / ⌘V / ⌘Z 交给搜索框。
    /// 面板不激活 App，⌘ 命令走不到 field editor，只能手动转发
    private func performEditingCommand(_ key: Character) -> Bool {
        let selectors: [Character: Selector] = [
            "a": #selector(NSTextView.selectAll(_:)),
            "x": #selector(NSTextView.cut(_:)),
            "c": #selector(NSTextView.copy(_:)),
            "v": #selector(NSTextView.paste(_:)),
            "z": Selector(("undo:")),
        ]
        guard let selector = selectors[key],
              let responder = panel.firstResponder,
              responder.responds(to: selector) else { return false }
        responder.doCommand(by: selector)
        return true
    }

    /// 输入法正在组词时一律放行，否则中文打不出字
    private func isComposing() -> Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return false }
        let range = editor.markedRange()
        return range.location != NSNotFound && range.length > 0
    }

    private func handle(_ event: NSEvent) -> Bool {
        if isComposing() { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.command) {
            // ⌘⌫ 才是「删除这条记录」。删除必须带修饰键：
            // 裸 ⌫ 是搜索框的退格，而在旧逻辑里空搜索时裸 ⌫ 会顺手删掉选中的记录——
            // 用户清空搜索后习惯性多按一下就误删了历史，这个坑必须堵死
            if Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
                let action = Self.deleteKeyAction(
                    isSnippetMode: viewModel.isSnippetMode,
                    query: viewModel.query,
                    hasSelection: viewModel.selectedItem != nil,
                    hasCommand: true,
                    alreadyHinted: didHintDeleteShortcut)
                guard action == .deleteItem else { return false }
                deleteSelected()
                return true
            }
            if let number = Int(chars), (1...9).contains(number) {
                viewModel.pasteQuick(number)
                return true
            }
            switch chars.lowercased() {
            case "m":
                // ⌘M 勾选当前行（再按一次取消）并下移，⌘⇧M 清空勾选。
                // 勾了多条后回车 = 合并粘贴，一次粘出
                if viewModel.isSnippetMode { return false }
                if flags.contains(.shift) {
                    viewModel.clearChecked()
                } else {
                    viewModel.toggleCheckAtSelection()
                }
                return true
            case "a", "x", "c", "v", "z":
                // 编辑命令直接转给搜索框的 field editor：
                // 面板是 nonactivating 的，AppKit 不会自动派发这类 ⌘ 命令
                return performEditingCommand(chars.lowercased().first ?? " ")
            case "p":
                guard !viewModel.isSnippetMode else { return false }
                if let item = viewModel.selectedItem { store.togglePin(item) }
                return true
            case ",":
                hide(returnFocus: false)
                onOpenSettings?(.general)
                return true
            case "w":
                hide()
                return true
            default:
                return false
            }
        }

        if flags.contains(.control), chars.lowercased() == "n" {
            viewModel.moveSelection(by: 1)
            return true
        }
        if flags.contains(.control), chars.lowercased() == "p" {
            viewModel.moveSelection(by: -1)
            return true
        }

        switch Int(event.keyCode) {
        case kVK_Return:
            // 有勾选就合并粘贴，否则粘当前行
            viewModel.pasteSelection(plainTextOnly: flags.contains(.shift))
            return true
        case kVK_Escape:
            // 预览被缩放钉住时，第一次 Esc 只收预览，别把整个面板关了
            if preview.isPinned {
                preview.hide()
                panel.makeKey()
                return true
            }
            hide()
            return true
        case kVK_Tab:
            viewModel.cycleFilter()
            resize()
            return true
        case kVK_DownArrow:
            viewModel.moveSelection(by: 1)
            return true
        case kVK_UpArrow:
            viewModel.moveSelection(by: -1)
            return true
        case kVK_RightArrow:
            // 空格不能用来开查看器——搜索框有焦点时空格要拿来输入
            guard !viewModel.isSnippetMode else { return false }
            if let item = viewModel.selectedItem { openImageViewer(for: item) }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            // 裸 ⌫ / ⌦ 一律还给搜索框，永远不删记录。
            // 删除改成 ⌘⌫：和 Finder 一致，也不会再把「清空搜索时的多余退格」变成误删。
            // 顺手提示一次快捷键（每次唤起最多一次），否则新用户找不到删除入口
            let action = Self.deleteKeyAction(
                isSnippetMode: viewModel.isSnippetMode,
                query: viewModel.query,
                hasSelection: viewModel.selectedItem != nil,
                hasCommand: false,
                alreadyHinted: didHintDeleteShortcut)
            if action == .hintOnce {
                didHintDeleteShortcut = true
                Toast.shared.show("按 ⌘⌫ 删除选中的这条", duration: 1.6)
            }
            return false
        default:
            return false
        }
    }

    // MARK: - 大图查看器

    func openImageViewer(for item: ClipItem) {
        guard item.kind == .image else { return }
        // 先留住原 App，hide 会把它清掉
        let app = previousApp
        hide(returnFocus: false)
        onOpenImageViewer?(item, app)
    }

    // MARK: - 粘贴

    private func deleteSelected() {
        guard let item = viewModel.selectedItem else { return }
        viewModel.delete(item)
        resize()
    }

    /// 删除键要怎么处理。抽成纯函数是为了能回归测试：
    /// 这里出过一个很难受的 bug —— 空搜索时裸 ⌫ 会删记录，
    /// 用户清空搜索后习惯性多按一下，就把历史里的条目删了。
    enum DeleteKeyAction: Equatable {
        /// ⌘⌫：删掉选中这条
        case deleteItem
        /// 裸 ⌫ 且搜索为空：不删，提示一次快捷键
        case hintOnce
        /// 其余情况：交还搜索框，走正常退格
        case passThrough
    }

    static func deleteKeyAction(isSnippetMode: Bool,
                                query: String,
                                hasSelection: Bool,
                                hasCommand: Bool,
                                alreadyHinted: Bool) -> DeleteKeyAction {
        // 片段不从浮窗删：误删代价太大，要删去设置页
        if isSnippetMode { return .passThrough }
        if hasCommand { return .deleteItem }
        // 裸 ⌫ 永远不删东西；只有「搜索已空 + 有选中 + 还没提示过」才提示一次
        let isEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty, hasSelection, !alreadyHinted { return .hintOnce }
        return .passThrough
    }

    /// 写完剪贴板后的统一收尾：有授权就顺手合成一次 ⌘V。
    /// 返回 true 表示已经自动粘出去了，调用方就不该再说「按 ⌘V」——
    /// 三个入口都用这一个判断，否则很容易出现「自动粘贴开着还提示按 ⌘V」的自相矛盾。
    @discardableResult
    private func autoPasteIfPossible() -> Bool {
        let trusted = PasteEngine.isTrusted
        if trusted { PasteEngine.postCommandV() }
        return trusted
    }

    /// 没授权时怎么提示。第一次多说一句「去哪儿开」，之后不再啰嗦
    private func showManualPasteHint(_ base: String) {
        let alreadyShown = AppSettings.shared.autoPasteHintShown
        let text = PasteEngine.manualPasteHint(base, alreadyShown: alreadyShown)
        if !alreadyShown { AppSettings.shared.autoPasteHintShown = true }
        Toast.shared.show(text, duration: text.count > base.count ? 3.4 : 1.8)
    }

    /// 合并粘贴：把勾选项拼成一段。有授权就直接粘出去
    private func pasteMerged(_ items: [ClipItem]) {
        hide()
        let ok = PasteEngine.writeMergedToPasteboard(items, imagesDirectory: store.imagesDirectory)
        monitor.skipChangesUpToNow()
        guard ok else {
            Toast.shared.show("这些内容没有可粘贴的文字", duration: 2.4)
            return
        }
        if autoPasteIfPossible() { return }
        showManualPasteHint("已复制 \(items.count) 条，按 ⌘V 粘贴")
    }

    /// 片段：展开变量后写回剪贴板。
    /// {{clipboard}} 要在写之前读——写完系统剪贴板就只剩片段内容了
    private func pasteSnippet(_ snippet: Snippet) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        hide()
        let text = SnippetExpander.expand(snippet.content, clipboard: clipboard)
        PasteEngine.writeStringToPasteboard(text)
        store.snippetStore?.markUsed(snippet)
        monitor.skipChangesUpToNow()
        if autoPasteIfPossible() { return }
        showManualPasteHint("已复制片段，按 ⌘V 粘贴")
    }

    /// 供大图查看器的「复制」复用
    func pasteItem(_ item: ClipItem, plainTextOnly: Bool = false) {
        hide()
        let ok = PasteEngine.writeToPasteboard(item, plainTextOnly: plainTextOnly,
                                               imagesDirectory: store.imagesDirectory)
        monitor.skipChangesUpToNow()
        let auto = autoPasteIfPossible()

        // 文件类在原文件已失效时只会写进文件名。不说清楚，用户会以为粘贴失败
        guard ok else {
            Toast.shared.show(auto ? "原文件已不可用，只粘贴了名称"
                                   : "原文件已不可用，只复制了名称，按 ⌘V 粘贴",
                              duration: 2.6)
            return
        }
        if auto { return }
        showManualPasteHint("已复制，按 ⌘V 粘贴")
    }


    @objc private func panelDidResignKey() {
        // 点到别的地方就收起来，不用手动 Esc
        // 鼠标移到预览上时它会拿走 key，这不是"点到别处"，不能把面板收了
        guard !preview.isKey else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.panel.isKeyWindow, !self.preview.isKey else { return }
            // 走到这里意味着用户已经把焦点给了别处（另一个 App、桌面、或自己的设置窗口）。
            // 不能再 activate 旧 App：那会把焦点硬抢回去，表现是"点一下别的窗口又被弹回来"。
            // 只有用户主动关闭（Esc）或选中粘贴时才需要还焦点，那两条路径走的是默认参数
            self.hide(returnFocus: false)
        }
    }
}
