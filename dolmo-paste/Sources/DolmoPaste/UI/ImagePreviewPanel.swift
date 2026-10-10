import AppKit
import SwiftUI

// MARK: - 状态

@MainActor
final class PreviewPanelModel: ObservableObject {
    @Published private(set) var item: ClipItem?
    @Published private(set) var image: NSImage?
    /// 放大镜：图片在卡片内缩放 + 平移
    @Published var zoom = ZoomState()
    @Published private(set) var caption: String = ""

    /// 缩放过就认为用户"抓住"了这张图，钉住不再自动消失
    var isPinned: Bool { zoom.isZoomed }

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
        zoom.pixelSize = loaded?.size ?? .zero

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
    /// 双击：已缩放就回到适应，否则放到原图 1:1
    let onToggleZoom: () -> Void

    @State private var dragStart: CGSize = .zero

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
            if model.zoom.isZoomed {
                Text(verbatim: model.zoom.percentText)
                    .foregroundStyle(theme.secondaryText)
            } else if showHint {
                Text("捏合缩放 · 可拖边放大")
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .font(theme.metaFont)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(height: Self.footerHeight)
    }

    private var footerText: String {
        guard let item = model.item else { return model.caption }
        return "\(model.caption) · \(TimeFormat.relative(item.copiedAt))"
    }

    /// 放大镜：图片在框里缩放 + 平移。整窗变大走系统原生的拖边，不在这里
    private var canvas: some View {
        GeometryReader { geo in
            Group {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(model.zoom.scale, anchor: .center)
                        .offset(model.zoom.offset)
                        .gesture(dragGesture)
                        .onTapGesture(count: 2, perform: onToggleZoom)
                        .animation(.easeOut(duration: 0.1), value: model.zoom.scale)
                } else {
                    Text("图片已失效")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { model.zoom.setContainer(geo.size) }
            .onChange(of: geo.size) { _, new in model.zoom.setContainer(new) }
        }
    }

    /// 拖动平移（放大之后才用得上）
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                model.zoom.pan(by: CGSize(
                    width: value.translation.width - dragStart.width,
                    height: value.translation.height - dragStart.height
                ))
                dragStart = value.translation
            }
            .onEnded { _ in dragStart = .zero }
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
final class ImagePreviewController {
    private let model = PreviewPanelModel()
    private let panel: PreviewPanel
    private var hosting: NSHostingView<HoverPreviewView>!
    private var autoHideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var globalMonitor: Any?
    private var resizeObserver: NSObjectProtocol?

    /// 贴合的主面板位置变化时跟着走
    weak var anchorWindow: NSWindow?

    var isVisible: Bool { panel.isVisible }
    var isPinned: Bool { model.isPinned }
    /// 当前是不是 key 窗口（主面板靠它判断要不要收起自己）
    var isKey: Bool { panel.isKeyWindow }

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
        hosting = NSHostingView(rootView: makeView())
        panel.contentView = hosting

        // 用户手动拖过的大小要记下来，下次预览沿用
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistScale() }
        }
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
            onClose: { [weak self] in self?.hide() },
            onToggleZoom: { [weak self] in self?.toggleZoom() }
        )
    }

    /// 样式切换后重挂视图
    func updateTheme(_ theme: PanelTheme) {
        self.theme = theme
        hosting.rootView = makeView()
    }

    // MARK: 尺寸

    /// 用户偏好的整体倍数：拖过一次之后记下来，下次预览还是这么大
    private static let scaleKey = "previewCardScale"
    private var cardScale: CGFloat {
        let v = UserDefaults.standard.object(forKey: Self.scaleKey) as? CGFloat
        return min(max(v ?? 1, 0.5), 3)
    }

    private var pixel: CGSize {
        CGSize(width: CGFloat(model.item?.imageWidth ?? 0), height: CGFloat(model.item?.imageHeight ?? 0))
    }

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
        let scale = cardScale
        let visible = visibleFrame()
        let maxW = visible.width - 24 - HoverPreviewView.chrome.width
        let maxH = visible.height - 24 - HoverPreviewView.chrome.height
        // 不许超出屏幕，也不许缩到 260 宽以下
        let k = min(scale, maxW / max(base.width, 1), maxH / max(base.height, 1))
        let grown = max(k, 260 / max(base.width * k, 1))
        let size = CGSize(width: (base.width * grown + HoverPreviewView.chrome.width).rounded(),
                          height: (base.height * grown + HoverPreviewView.chrome.height).rounded())
        // 原生拖拽的上下限：最小别缩没，最大别拖出屏幕
        panel.contentMinSize = CGSize(width: 260, height: 180)
        panel.contentMaxSize = CGSize(width: max(visible.width - 24, 300),
                                      height: max(visible.height - 24, 220))
        // setContentSize 自己会触发 didResize，必须挡掉：
        // 否则会被当成"用户拖过"写进持久化，下次再乘一遍，窗口越用越大
        isApplyingSize = true
        panel.setContentSize(size)
        DispatchQueue.main.async { self.isApplyingSize = false }
        hosting.frame = NSRect(origin: .zero, size: size)
        reposition()
    }

    /// 正在由代码设置尺寸（不是用户拖的）
    private var isApplyingSize = false

    /// 用户拖完窗口后把"相对默认多大"记下来
    private func persistScale() {
        guard !isApplyingSize else { return }
        let base = defaultImageArea()
        guard base.width > 0 else { return }
        let area = CGSize(width: panel.frame.width - HoverPreviewView.chrome.width,
                          height: panel.frame.height - HoverPreviewView.chrome.height)
        let scale = min(max(area.width / base.width, 0.5), 3)
        UserDefaults.standard.set(scale, forKey: Self.scaleKey)
    }

    func show(_ item: ClipItem, imagesDirectory: URL) {
        cancelAutoHide()
        model.show(item, imagesDirectory: imagesDirectory)
        if !panel.isVisible {
            hosting.rootView = makeView()
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: Self.hintKey) + 1, forKey: Self.hintKey)
        }
        applyCardSize()
        if !panel.isVisible {
            panel.orderFront(nil)
            installGlobalMonitor()
        }
    }

    /// 悬停行在屏幕上的纵坐标（取悬停那一刻的鼠标位置）：预览卡对齐这一行，而不是浮窗中心
    private var focusY: CGFloat?

    /// 带一点延迟再显示：鼠标快速划过列表时不至于每张图都去读一遍原图
    func scheduleShow(_ item: ClipItem, imagesDirectory: URL, delay: TimeInterval = 0.08) {
        cancelAutoHide()
        // 已经钉住（缩放过）就不跟着别的行跳
        if !model.isPinned { focusY = NSEvent.mouseLocation.y }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.show(item, imagesDirectory: imagesDirectory)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        cancelAutoHide()
        showWork?.cancel()
        showWork = nil
        removeGlobalMonitor()
        if panel.isKeyWindow { panel.resignKey() }
        // 收起来就当作这次预览结束，下次重新显示时不该带着上次的缩放
        model.zoom.reset()
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
    func scheduleAutoHide() {
        cancelAutoHide()
        showWork?.cancel()
        showWork = nil
        // 缩放过就是用户主动"抓住"了这张图，不自动收
        guard !model.isPinned else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 不靠 hover 判断鼠标在不在预览上：不激活的面板收不到 mouseMoved。
            // 直接看坐标，鼠标还在预览上就继续等
            if self.panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleAutoHide()
                return
            }
            self.hide()
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func cancelAutoHide() {
        autoHideWork?.cancel()
        autoHideWork = nil
    }

    // MARK: 滚轮 / 捏合（放大镜）

    /// 手势 → 缩放系数
    private static func zoomFactor(for event: NSEvent) -> CGFloat? {
        switch event.type {
        case .scrollWheel:
            guard event.scrollingDeltaY != 0 else { return nil }
            let sensitivity: CGFloat = event.modifierFlags.contains(.command) ? 0.0015 : 0.0045
            return exp(event.scrollingDeltaY * sensitivity)
        case .magnify:
            guard event.magnification != 0 else { return nil }
            return 1 + event.magnification
        default:
            return nil
        }
    }

    private func zoom(by factor: CGFloat) {
        guard model.item != nil else { return }
        cancelAutoHide()
        model.zoom.zoom(by: factor)
    }

    /// 双击：已缩放就回到适应，否则放到原图 1:1
    private func toggleZoom() {
        if model.zoom.isZoomed { model.zoom.reset() } else { model.zoom.zoomToActual() }
    }

    /// 鼠标在预览面板内才吃事件，否则放行给列表滚动
    func consume(_ event: NSEvent) -> Bool {
        guard panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) else { return false }
        guard let factor = Self.zoomFactor(for: event) else { return false }
        zoom(by: factor)
        return true
    }

    /// 兜底：本 App 是菜单栏应用，即便抢了 key 也可能有事件落到别的 App。
    /// 全局监听能看到"发给别的 App"的那部分，只要鼠标在预览上就照样缩放。
    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self,
                  self.panel.isVisible,
                  self.panel.frame.contains(NSEvent.mouseLocation),
                  let factor = Self.zoomFactor(for: event) else { return }
            DispatchQueue.main.async { self.zoom(by: factor) }
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
        guard let anchor = anchorWindow else { return }
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
