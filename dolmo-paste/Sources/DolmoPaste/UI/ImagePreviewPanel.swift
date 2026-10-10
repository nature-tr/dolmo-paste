import AppKit
import SwiftUI

// MARK: - 状态

@MainActor
final class PreviewPanelModel: ObservableObject {
    @Published private(set) var item: ClipItem?
    @Published private(set) var image: NSImage?
    @Published var zoom = ZoomState()
    @Published private(set) var caption: String = ""
    // 用户保留预览与图片倍率无关，回到 Fit 也不应突然切图。
    @Published private(set) var isPinned = false
    func pin() { isPinned = true }
    func endSession() { isPinned = false; zoom.reset() }

    func show(_ item: ClipItem, imagesDirectory: URL) {
        let isSame = self.item?.id == item.id
        self.item = item

        if !isSame {
            load(item, imagesDirectory: imagesDirectory)
            zoom.reset()
        }
    }

    private func load(_ item: ClipItem, imagesDirectory: URL) {
        // 用落盘原图，缩略图只有 400px，一放大就糊
        var loaded: NSImage?
        if let name = item.imageFileName {
            loaded = NSImage(contentsOf: imagesDirectory.appendingPathComponent(name))
        }
        if loaded == nil, let data = item.thumbnailData {
            loaded = NSImage(data: data)
        }
        image = loaded
        zoom.setImagePixels(ImagePixelGeometry.size(of: loaded))

        var parts = ["\(item.imageWidth) × \(item.imageHeight)"]
        if item.imageTruncated { parts.append("仅缩略图") }
        caption = parts.joined(separator: " · ")
    }
}

// MARK: - 视图

/// 预览卡：和浮窗同一种材质、同一个圆角，图片嵌在里面留 6pt 边，底下一条信息行。
/// 窗口本身是系统原生可缩放的（拖任意边/角），拖大 = 整张图变大。
struct HoverPreviewView: View {
    @ObservedObject var model: PreviewPanelModel
    let theme: PanelTheme
    /// 缩放提示只在前几次出现，学会了就不再打扰
    let showHint: Bool
    let onClose: () -> Void
    let onInteraction: () -> Void
    let onWindowDrag: () -> Void

    static let framePadding: CGFloat = 6
    static let footerHeight: CGFloat = 28
    /// 窗口四边 chrome：左右各 framePadding，上面 framePadding、下面信息行
    static var chrome: CGSize { CGSize(width: framePadding * 2, height: framePadding + footerHeight) }

    /// 小图也别缩成一小块：最小显示尺寸（会放大到原图之上，但不超过 2 倍）
    private static let minImageWidth: CGFloat = 300
    private static let minImageHeight: CGFloat = 160

    /// 整张图的最大显示框。按屏幕算，小屏上别把卡片撑爆。
    /// 预览是贴在浮窗右边的，宽度要留得下浮窗（dolmo 700 / system 640）+ 12pt 间距
    private static func maxImageBox() -> CGSize {
        let frame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1512, height: 900)
        return CGSize(
            width: min(660, max(440, frame.width * 0.36)),
            height: min(540, max(360, frame.height * 0.52))
        )
    }

    /// 默认尺寸下整张图的显示系数（相对原图）
    private static func fitFactor(forPixel pixel: CGSize) -> CGFloat {
        let box = maxImageBox()
        guard pixel.width > 0, pixel.height > 0 else { return 1 }
        // 整张图等比缩到框里；最多放到原图 1:1
        let fitToBox = min(box.width / pixel.width, box.height / pixel.height, 1)
        // 小图整体放大到最小尺寸（原图太小的话最多 2 倍，不然马赛克太明显）
        let fitToMin = max(minImageWidth / pixel.width, minImageHeight / pixel.height)
        return max(fitToBox, min(min(fitToMin, box.width / pixel.width, box.height / pixel.height), 2))
    }

    /// 按图片比例算卡片尺寸（默认大小）。控制器据此调整面板大小，截图模式也用它
    static func cardSize(forPixel pixel: CGSize) -> CGSize {
        let box = maxImageBox()
        guard pixel.width > 0, pixel.height > 0 else {
            return CGSize(width: box.width + chrome.width, height: box.height + chrome.height)
        }
        let fit = Self.fitFactor(forPixel: pixel)
        let imageW = (pixel.width * fit).rounded()
        let imageH = (pixel.height * fit).rounded()
        return CGSize(width: imageW + chrome.width, height: imageH + chrome.height)
    }

    private var innerRadius: CGFloat { max(theme.cornerRadius - Self.framePadding, 4) }

    var body: some View {
        VStack(spacing: 0) {
            canvas
                .background(theme.kind == .dolmo ? theme.sidebarBackground : Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if model.isPinned {
                        closeButton.padding(6).transition(.opacity)
                    }
                }
            footer
        }
        .padding([.top, .horizontal], Self.framePadding)
        .background {
            if theme.useMaterial {
                VisualEffectBackground(material: .popover)
            } else {
                Rectangle().fill(theme.background)
            }
        }
        // 和浮窗同一个圆角、同一条描边，贴在一起才像一套
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.8), lineWidth: 0.5)
        )
        // 窗口是 titled 的（原生可缩放的前提），SwiftUI 会给顶部加 32pt 安全区，
        // 这里自己管顶部，不然卡片上方会空一条
        .ignoresSafeArea()
        // 窗口可以被拖得跟图片比例不一致，多出来的地方填窗口底色，不留透明洞
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text(verbatim: footerText)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 8)
            if model.isPinned {
                Text(verbatim: model.zoom.percentText)
                    .foregroundStyle(theme.secondaryText)
            } else if showHint {
                Text("捏合缩放 · 拖空白移动")
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .font(theme.metaFont)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(height: Self.footerHeight)
        .overlay { NativeWindowDragArea(onDrag: onWindowDrag) }
    }

    private var footerText: String {
        guard let item = model.item else { return model.caption }
        return "\(model.caption) · \(TimeFormat.relative(item.copiedAt))"
    }

    private var canvas: some View {
        NativeImageCanvas(image: model.image, zoom: $model.zoom, movesWindow: true,
                          onInteraction: onInteraction, onWindowDrag: onWindowDrag)
            .overlay {
                if model.image == nil {
                    Text("图片已失效").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                        .allowsHitTesting(false)
                }
            }
    }

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .onTapGesture(perform: onClose)
    }
}

// MARK: - 窗口

/// 预览窗口做成"带标题栏但全透明"：
/// 只有 `.titled + .resizable` 才有系统原生的拖边/拖角改大小，borderless 窗口拿不到。
/// 标题栏透明 + 隐藏标题 + 不挂红绿灯，看上去仍是一张无边框卡片。
/// 同时允许 become key：鼠标移上来要拿到 key，否则捏合手势会派发给别的 App 的 key window。
private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ImagePreviewController: NSObject, NSWindowDelegate {
    private let model = PreviewPanelModel()
    private let panel: PreviewPanel
    private var hosting: NSHostingView<HoverPreviewView>!
    private var autoHideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var globalMonitor: Any?
    private var generation = 0
    private var hoveredItemID: UUID?
    private var detached = false
    private var isHiding = false
    var onResignKey: (() -> Void)?
    var onClosePreview: (() -> Void)?

    /// 贴合的主面板位置变化时跟着走
    weak var anchorWindow: NSWindow?

    var isVisible: Bool { panel.isVisible }
    var isPinned: Bool { model.isPinned }
    /// 当前是不是 key 窗口（主面板靠它判断要不要收起自己）
    var isKey: Bool { panel.isKeyWindow }
    func owns(_ event: NSEvent) -> Bool { event.window === panel }

    init(theme: PanelTheme) {
        let size = HoverPreviewView.cardSize(forPixel: .zero)
        panel = PreviewPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // 背景交给 SwiftUI 画，圆角外面要是透明的
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // 不激活的窗口默认不收 mouseMoved，打开后 hover 之类的交互才有反应
        panel.acceptsMouseMovedEvents = true

        self.theme = theme
        super.init()
        hosting = NSHostingView(rootView: makeView())
        panel.contentView = hosting
        panel.delegate = self
        panel.isMovableByWindowBackground = false
    }

    private var theme: PanelTheme

    /// 前 3 次预览显示提示，之后不再出现
    private static let hintKey = "previewHintShownCount"
    private var showHint: Bool { UserDefaults.standard.integer(forKey: Self.hintKey) < 3 }

    private func makeView() -> HoverPreviewView {
        HoverPreviewView(
            model: model,
            theme: theme,
            showHint: showHint,
            onClose: { [weak self] in self?.hide(); self?.onClosePreview?() },
            onInteraction: { [weak self] in self?.pin() },
            onWindowDrag: { [weak self] in self?.pin(); self?.detached = true }
        )
    }

    /// 样式切换后重挂视图
    func updateTheme(_ theme: PanelTheme) {
        self.theme = theme
        hosting.rootView = makeView()
    }

    // MARK: 尺寸

    /// 只保存用户 live-resize 完成后的二维尺寸；程序化布局不写设置。
    private static let widthKey = "previewWindowWidth"
    private static let heightKey = "previewWindowHeight"
    private var pixel: CGSize { model.zoom.pixelSize }

    /// 默认卡片里图片区的尺寸
    private func defaultImageArea() -> CGSize {
        let card = HoverPreviewView.cardSize(forPixel: pixel)
        return CGSize(width: card.width - HoverPreviewView.chrome.width,
                      height: card.height - HoverPreviewView.chrome.height)
    }

    private func visibleFrame() -> CGRect {
        panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func applyCardSize() {
        let base = defaultImageArea()
        let visible = visibleFrame()
        let savedW = UserDefaults.standard.double(forKey: Self.widthKey)
        let savedH = UserDefaults.standard.double(forKey: Self.heightKey)
        let size = CGSize(
            width: min(max(savedW > 0 ? savedW : base.width + HoverPreviewView.chrome.width, 260), visible.width - 24),
            height: min(max(savedH > 0 ? savedH : base.height + HoverPreviewView.chrome.height, 180), visible.height - 24)
        )
        // 原生拖拽的上下限：最小别缩没，最大别拖出屏幕
        panel.contentMinSize = CGSize(width: 260, height: 180)
        panel.contentMaxSize = CGSize(width: max(visible.width - 24, 300),
                                      height: max(visible.height - 24, 220))
        panel.setContentSize(size)
        reposition()
    }

    func windowWillStartLiveResize(_ notification: Notification) { pin() }
    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.contentView?.bounds.size ?? .zero
        UserDefaults.standard.set(size.width, forKey: Self.widthKey)
        UserDefaults.standard.set(size.height, forKey: Self.heightKey)
    }
    func windowDidResignKey(_ notification: Notification) {
        if !isHiding { onResignKey?() }
    }
    private func pin() {
        cancelAutoHide()
        showWork?.cancel()
        showWork = nil
        hoveredItemID = nil
        generation += 1
        model.pin()
    }

    func show(_ item: ClipItem, imagesDirectory: URL) {
        guard !panel.isVisible || !model.isPinned || model.item?.id == item.id else { return }
        cancelAutoHide()
        let isNewSession = !panel.isVisible
        let changedImage = model.item?.id != item.id
        model.show(item, imagesDirectory: imagesDirectory)
        if isNewSession {
            detached = false
            hosting.rootView = makeView()
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: Self.hintKey) + 1, forKey: Self.hintKey)
        }
        if isNewSession || changedImage { applyCardSize() }
        if !panel.isVisible {
            panel.orderFront(nil)
            installGlobalMonitor()
        }
    }

    /// 悬停行在屏幕上的纵坐标（取悬停那一刻的鼠标位置）：预览卡对齐这一行，而不是浮窗中心
    private var focusY: CGFloat?

    /// 带一点延迟再显示：鼠标快速划过列表时不至于每张图都去读一遍原图
    func scheduleShow(_ item: ClipItem, imagesDirectory: URL, delay: TimeInterval = 0.08) {
        guard !model.isPinned else { return }
        cancelAutoHide()
        focusY = NSEvent.mouseLocation.y
        hoveredItemID = item.id
        generation += 1
        let token = generation
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.hoveredItemID == item.id, !self.model.isPinned else { return }
            self.showWork = nil
            self.show(item, imagesDirectory: imagesDirectory)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        isHiding = true
        defer { isHiding = false }
        generation += 1
        hoveredItemID = nil
        cancelAutoHide()
        showWork?.cancel()
        showWork = nil
        removeGlobalMonitor()
        if panel.isKeyWindow { panel.resignKey() }
        // 收起来就当作这次预览结束，下次重新显示时不该带着上次的缩放
        model.endSession()
        panel.orderOut(nil)
    }

    // MARK: key（捏合/滚轮要靠它）

    /// 鼠标移到预览上就抢 key。不这样手势会被派发给前台别的 App 的 key window，
    /// 本地监听根本收不到（这是"捏合监听不到"的根因）
    func takeKeyIfMouseInside() {
        guard panel.isVisible, !panel.isKeyWindow,
              panel.frame.contains(NSEvent.mouseLocation) else { return }
        panel.makeKey()
    }

    func resignKey() {
        if panel.isKeyWindow { panel.resignKey() }
    }

    // MARK: 自动隐藏

    /// 鼠标离开列表项：先不急着收，留出时间让鼠标移到预览上
    func endHover(_ item: ClipItem) {
        guard hoveredItemID == item.id else { return }
        hoveredItemID = nil
        generation += 1
        scheduleAutoHide()
    }

    func scheduleAutoHide() {
        cancelAutoHide()
        showWork?.cancel()
        showWork = nil
        // 缩放过就是用户主动"抓住"了这张图，不自动收
        guard !model.isPinned else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.model.isPinned else { return }
            // 不靠 hover 判断鼠标在不在预览上：不激活的面板收不到 mouseMoved。
            // 直接看坐标，鼠标还在预览上就继续等
            if self.panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleAutoHide()
                return
            }
            self.hide()
            self.onClosePreview?()
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func cancelAutoHide() {
        autoHideWork?.cancel()
        autoHideWork = nil
    }

    // MARK: 唯一画布事件入口

    private func canvas(in view: NSView) -> ImageCanvasView? {
        if let canvas = view as? ImageCanvasView { return canvas }
        return view.subviews.lazy.compactMap { self.canvas(in: $0) }.first
    }
    /// 本地手势只对当前预览窗口和画布生效，消费后不会再次进入 responder。
    func consume(_ event: NSEvent) -> Bool {
        guard panel.isVisible, event.window === panel,
              let canvas = canvas(in: hosting) else { return false }
        return canvas.consumeZoom(event)
    }
    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .magnify]) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            self.takeKeyIfMouseInside()
            guard event.type != .mouseMoved, let canvas = self.canvas(in: self.hosting) else { return }
            let screenRect = self.panel.convertToScreen(canvas.convert(canvas.bounds, to: nil))
            guard screenRect.contains(NSEvent.mouseLocation) else { return }
            // 全局只补发给其他 App 的事件，仍走同一画布入口；不排队跨会话回写。
            canvas.applyZoom(event)
        }
    }

    private func removeGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    // MARK: 定位

    /// 贴在主面板旁边：右边放得下就放右边，否则翻到左边
    func reposition() {
        guard !detached, !model.isPinned, let anchor = anchorWindow else { return }
        let size = panel.frame.size
        let anchorFrame = anchor.frame
        let visible = visibleFrame()
        let gap: CGFloat = 12

        var x = anchorFrame.maxX + gap
        if x + size.width > visible.maxX {
            x = anchorFrame.minX - gap - size.width
        }
        // 两边都放不下（小屏）就贴着屏幕边缘，宁可压一点主面板也要露出来
        x = min(max(x, visible.minX + 8), max(visible.maxX - size.width - 8, visible.minX + 8))

        // 垂直方向以悬停行为中心，但不超出浮窗上下边（卡比浮窗高时退回居中）
        var y = anchorFrame.midY - size.height / 2
        if let focusY, size.height < anchorFrame.height {
            y = min(max(focusY - size.height / 2, anchorFrame.minY), anchorFrame.maxY - size.height)
        }
        y = min(max(y, visible.minY + 8), max(visible.maxY - size.height - 8, visible.minY + 8))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
