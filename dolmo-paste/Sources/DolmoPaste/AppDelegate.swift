import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store: ClipStore!
    private var monitor: ClipboardMonitor!
    private var panelController: ClipPanelController!
    private var mainWindow: NSWindow?
    private var imageViewer: ImageViewerController?
    /// 打开查看器前的原 App，关掉后焦点还回去
    private var viewerPreviousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try ClipStore()
            // 上次开了 OCR 但还没扫完的（比如中途退出），这次启动接着扫
            store.backfillOCR()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "无法初始化本地数据库"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        monitor = ClipboardMonitor()
        monitor.onCapture = { [weak self] content in
            self?.store.add(content)
        }
        monitor.start()

        panelController = ClipPanelController(store: store, monitor: monitor)
        panelController.onOpenSettings = { [weak self] in self?.openMainWindow() }
        panelController.onOpenImageViewer = { [weak self] item, app in
            self?.showImageViewer(for: item, previousApp: app)
        }

        HotkeyManager.shared.onTrigger = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.panelController.toggle() }
        }
        if !HotkeyManager.shared.register() {
            print("[dolmo paste] 全局热键注册失败，快捷键可能被其他 App 占用")
        }

        setupStatusItem()
        promptAccessibilityIfNeeded()

        // 第一次启动主动把主窗口亮出来：菜单栏应用装完只多一个图标，
        // 用户根本不知道装成功了没有
        let launchedKey = "hasOpenedMainWindow"
        if !UserDefaults.standard.bool(forKey: launchedKey) {
            UserDefaults.standard.set(true, forKey: launchedKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openMainWindow()
            }
        }

        // 旧记录缺图标，启动后补一次（延后执行，不拖慢启动）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            store.backfillIcons()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
        monitor?.stop()
    }

    // MARK: - 菜单栏

    /// 菜单栏图标：橙子剪影（圆果 + 右上一片叶），模板图，跟随菜单栏深浅自动反色
    private static func orangeSilhouette() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // 果身
            ctx.addEllipse(in: CGRect(x: 2.5, y: 1.5, width: 13, height: 13))
            ctx.fillPath()
            // 叶子：两段弧围成的柳叶形，斜向右上
            let leaf = CGMutablePath()
            leaf.move(to: CGPoint(x: 9.2, y: 13.6))
            leaf.addQuadCurve(to: CGPoint(x: 16.2, y: 17.2), control: CGPoint(x: 11.0, y: 18.4))
            leaf.addQuadCurve(to: CGPoint(x: 9.2, y: 13.6), control: CGPoint(x: 14.6, y: 12.6))
            leaf.closeSubpath()
            // 叶子和果身之间抠出一圈缝，小尺寸下也分得清
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.addPath(leaf)
            ctx.setLineWidth(2.4)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(leaf)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "dolmo paste"
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Self.orangeSilhouette()
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // 左键 = 主窗口；剪贴板历史只走 ⌘⇧V
            openMainWindow()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = menu.addItem(withTitle: "打开历史（⌘⇧V）", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        let clearItem = menu.addItem(withTitle: "清除历史…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(.separator())
        // 退出的 action 在 NSApp 上，target 必须留空走响应链；
        // 设成 self 会让菜单自动验证判定"不响应"而置灰
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openPanel() {
        panelController.show()
    }

    /// 点 Dock 里的图标和点菜单栏图标走同一条路：打开主窗口。
    /// 不实现这个，Dock 图标点下去没反应——菜单栏应用没有默认窗口可 reopen
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
            mainWindow?.orderFrontRegardless()
        } else {
            openMainWindow()
        }
        return false
    }

    // MARK: - 主窗口

    /// --settings 调试入口也要用，所以不是 private
    @objc func openMainWindow() {
        if mainWindow == nil {
            // 必须和 MainWindowView.windowSize 一致：
            // 窗口比内容大时 SwiftUI 会把内容居中，顶部就多出一圈空白
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: MainWindowView.windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "dolmo paste"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // 背景交给 SwiftUI 画，切换外观样式时才会跟着变
            window.backgroundColor = .clear
            window.contentView = NSHostingView(rootView: MainWindowView(store: store))
            window.center()
            window.isReleasedWhenClosed = false
            // 窗口可能停在另一个桌面，激活时把它带到当前桌面
            window.collectionBehavior.insert(.moveToActiveSpace)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(mainWindowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
            mainWindow = window
        }

        // 把主窗口提到最前，有三道坎，缺一个就会"点了没反应/只是出现但还在下面"：
        //   1. 菜单栏应用是 .accessory，窗口不会被 activate 带到最前 —— 先临时切成 .regular
        //   2. setActivationPolicy 要跑完一个 runloop 才生效 —— 所以 activate 放到下一个 tick
        //   3. 窗口已经存在只是被别的 App 压住时，makeKeyAndOrderFront 只抬得动"本应用内"的
        //      层级，跨应用抬不动 —— 必须再补一次 orderFrontRegardless
        panelController.hide(returnFocus: false)

        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.mainWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// 主窗口关掉后退回菜单栏应用，避免长期占着 Dock 和 Command-Tab
    @objc private func mainWindowWillClose() {
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    // MARK: - 大图查看器

    private func showImageViewer(for item: ClipItem, previousApp: NSRunningApplication?) {
        let viewer = imageViewer ?? ImageViewerController()
        imageViewer = viewer
        viewerPreviousApp = previousApp

        viewer.onClose = { [weak self] in
            self?.updateActivationPolicy()
            if let app = self?.viewerPreviousApp,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                app.activate()
            }
            self?.viewerPreviousApp = nil
        }
        viewer.onCopy = { [weak self] item in
            guard let self else { return }
            PasteEngine.writeToPasteboard(item, plainTextOnly: false, imagesDirectory: store.imagesDirectory)
            monitor.skipChangesUpToNow()
            Toast.shared.show("已复制", duration: 1.2)
        }
        viewer.onPaste = { [weak self] item in
            guard let self else { return }
            // 走 self.imageViewer 而不是闭包捕获的 viewer，避免 viewer → 闭包 → viewer 循环引用
            self.imageViewer?.close()
            // 焦点刚切回原 App，等它真正拿到前台再发 ⌘V，否则会落到错误的 App
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.panelController.pasteItem(item)
            }
        }

        viewer.show(item: item, imagesDirectory: store.imagesDirectory)
    }

    /// 有普通窗口时才当普通应用，否则退回菜单栏应用
    private func updateActivationPolicy() {
        let hasWindow = mainWindow?.isVisible == true || imageViewer?.isVisible == true
        NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清除全部历史？"
        alert.informativeText = "图片文件会一起删除，无法恢复。"
        alert.addButton(withTitle: "清除（保留固定项）")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "全部清除")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.clearAll(includePinned: false)
        case .alertThirdButtonReturn:
            store.clearAll(includePinned: true)
        default:
            break
        }
    }

    // MARK: - 首次权限引导

    private func promptAccessibilityIfNeeded() {
        let key = "didPromptAccessibility"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !PasteEngine.isTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        dolmo paste 用它做两件事：
        · 选中一条历史后直接粘贴进你正在用的 App，而不是只放回剪贴板
        · 把浮窗显示在光标旁边

        你复制的内容只存在这台 Mac 上，不会上传。
        """
        alert.addButton(withTitle: "前往系统设置")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            PasteEngine.openAccessibilitySettings()
        }
    }
}
