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

    var onOpenSettings: (() -> Void)?
    /// 打开大图查看器。带出 previousApp，查看器关掉后焦点还回原 App
    var onOpenImageViewer: ((ClipItem, NSRunningApplication?) -> Void)?

    private static let axFocusedUIElement = "AXFocusedUIElement" as CFString
    private static let axFrame = "AXFrame" as CFString

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
        preview.hide()

        // 样式可能刚被改过，每次唤起都重挂一遍
        let currentTheme = theme
        hosting.rootView = ClipPanelView(viewModel: viewModel, theme: currentTheme)
        preview.updateTheme(currentTheme)

        resize()
        position(near: caretPoint())
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
        let height = currentTheme.panelHeight(rowCount: viewModel.filtered.count)
        panel.setContentSize(NSSize(width: currentTheme.panelWidth, height: height))
        hosting.frame = NSRect(x: 0, y: 0, width: currentTheme.panelWidth, height: height)
        preview.reposition()
    }

    @objc private func panelDidMove() {
        preview.reposition()
    }

    /// 优先定位到输入光标（需辅助功能权限），回退到鼠标位置 —— 眼球不用离开正在编辑的地方
    private func caretPoint() -> CGPoint? {
        if PasteEngine.isTrusted() {
            let system = AXUIElementCreateSystemWide()
            var focusedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(system, Self.axFocusedUIElement, &focusedValue) == .success {
                let focused = focusedValue as! AXUIElement
                var frameValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, Self.axFrame, &frameValue) == .success {
                    var frame = CGRect.zero
                    if AXValueGetValue(frameValue as! AXValue, .cgRect, &frame), !frame.isNull {
                        // AX 坐标原点在左上，Cocoa 在左下
                        let screenHeight = NSScreen.main?.frame.height ?? 900
                        return CGPoint(x: frame.minX, y: screenHeight - frame.minY)
                    }
                }
            }
        }
        return nil
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
            if let number = Int(chars), (1...9).contains(number) {
                viewModel.pasteQuick(number)
                return true
            }
            switch chars.lowercased() {
            case "a", "x", "c", "v", "z":
                // 编辑命令直接转给搜索框的 field editor：
                // 面板是 nonactivating 的，AppKit 不会自动派发这类 ⌘ 命令
                return performEditingCommand(chars.lowercased().first ?? " ")
            case "p":
                if let item = viewModel.selectedItem { store.togglePin(item) }
                return true
            case ",":
                hide(returnFocus: false)
                onOpenSettings?()
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
            viewModel.paste(index: viewModel.selectedIndex, plainTextOnly: flags.contains(.shift))
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
            if let item = viewModel.selectedItem { openImageViewer(for: item) }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            // 搜索框非空时必须放行给输入框正常退格，只有空时退格才是"删除记录"
            if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deleteSelected()
                return true
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

    /// 供大图查看器的「粘贴」复用：写完剪贴板再模拟 ⌘V
    func pasteItem(_ item: ClipItem, plainTextOnly: Bool = false) {
        hide()
        PasteEngine.writeToPasteboard(item, plainTextOnly: plainTextOnly, imagesDirectory: store.imagesDirectory)
        monitor.skipChangesUpToNow()

        guard AppSettings.shared.autoPaste else { return }

        // 没有辅助功能权限时只写回了剪贴板，必须明确告知，否则看起来像"点了没反应"
        guard PasteEngine.isTrusted() else {
            Toast.shared.show("已复制到剪贴板，按 ⌘V 粘贴（未授权辅助功能，无法直接粘贴）", duration: 3.2)
            return
        }

        let delay = max(AppSettings.shared.pasteDelayMs, 20)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) {
            PasteEngine.postCommandV()
        }
    }

    @objc private func panelDidResignKey() {
        // 点到别的地方就收起来，不用手动 Esc
        // 鼠标移到预览上时它会拿走 key，这不是"点到别处"，不能把面板收了
        guard !preview.isKey else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.panel.isKeyWindow, !self.preview.isKey else { return }
            self.hide()
        }
    }
}
