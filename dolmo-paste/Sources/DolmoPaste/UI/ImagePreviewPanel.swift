import AppKit
import SwiftUI

// MARK: - 状态

@MainActor
final class PreviewPanelModel: ObservableObject {
    @Published private(set) var item: ClipItem?
    @Published private(set) var image: NSImage?
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
/// 信息行左边是尺寸 · 时间，右边是缩放倍率（前几次是「捏合缩放」提示）。
struct HoverPreviewView: View {
    @ObservedObject var model: PreviewPanelModel
    let theme: PanelTheme
    /// 缩放提示只在前几次出现，学会了就不再打扰
    let showHint: Bool
    let onClose: () -> Void

    @State private var dragStart: CGSize = .zero

    private static let maxImageBox = CGSize(width: 420, height: 380)
    private static let minImageWidth: CGFloat = 240
    static let framePadding: CGFloat = 6
    static let footerHeight: CGFloat = 28

    /// 按图片比例算卡片尺寸。控制器据此调整面板大小，截图模式也用它
    static func cardSize(forPixel pixel: CGSize) -> CGSize {
        let chromeW = framePadding * 2
        let chromeH = framePadding + footerHeight
        guard pixel.width > 0, pixel.height > 0 else {
            return CGSize(width: maxImageBox.width + chromeW, height: maxImageBox.height + chromeH)
        }
        let fit = min(maxImageBox.width / pixel.width, maxImageBox.height / pixel.height, 1)
        let imageW = max((pixel.width * fit).rounded(), minImageWidth)
        let imageH = max((pixel.height * fit).rounded(), 120)
        return CGSize(width: imageW + chromeW, height: imageH + chromeH)
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
                Text("捏合或滚轮缩放")
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
                        .onTapGesture(count: 2) {
                            if model.zoom.isZoomed { model.zoom.reset() } else { model.zoom.zoomToActual() }
                        }
                        .animation(.easeOut(duration: 0.1), value: model.zoom.scale)
                } else {
                    Text("图片已失效")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { model.zoom.containerSize = geo.size }
            .onChange(of: geo.size) { _, new in model.zoom.containerSize = new }
        }
    }

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

/// 预览是不激活、不抢 key 的面板：
/// 一旦抢 key，主面板会 resignKey 触发自动隐藏，整个面板就收起来了。
private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ImagePreviewController {
    private let model = PreviewPanelModel()
    private let panel: PreviewPanel
    private var hosting: NSHostingView<HoverPreviewView>!
    private var autoHideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?

    /// 贴合的主面板位置变化时跟着走
    weak var anchorWindow: NSWindow?

    var isVisible: Bool { panel.isVisible }
    var isPinned: Bool { model.isPinned }

    init(theme: PanelTheme) {
        let size = HoverPreviewView.cardSize(forPixel: .zero)
        panel = PreviewPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        // 不激活的窗口默认不收 mouseMoved，打开后 hover 之类的交互才有反应
        panel.acceptsMouseMovedEvents = true

        self.theme = theme
        hosting = NSHostingView(rootView: makeView())
        panel.contentView = hosting
    }

    private var theme: PanelTheme

    /// 前 3 次预览显示「捏合或滚轮缩放」，之后不再出现
    private static let hintKey = "previewHintShownCount"
    private var showHint: Bool { UserDefaults.standard.integer(forKey: Self.hintKey) < 3 }

    private func makeView() -> HoverPreviewView {
        HoverPreviewView(model: model, theme: theme, showHint: showHint) { [weak self] in
            self?.hide()
        }
    }

    /// 样式切换后重挂视图
    func updateTheme(_ theme: PanelTheme) {
        self.theme = theme
        hosting.rootView = makeView()
    }

    func show(_ item: ClipItem, imagesDirectory: URL) {
        cancelAutoHide()
        let isNewItem = model.item?.id != item.id
        model.show(item, imagesDirectory: imagesDirectory)
        if isNewItem || !panel.isVisible {
            // 卡片比例跟随图片
            let size = HoverPreviewView.cardSize(forPixel: CGSize(width: item.imageWidth, height: item.imageHeight))
            panel.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
        }
        if !panel.isVisible {
            hosting.rootView = makeView()
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: Self.hintKey) + 1, forKey: Self.hintKey)
        }
        reposition()
        if !panel.isVisible { panel.orderFront(nil) }
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
        // 收起来就当作这次预览结束，下次重新显示时不该带着上次的缩放
        model.zoom.reset()
        panel.orderOut(nil)
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

    // MARK: 滚轮 / 捏合

    /// 鼠标在预览面板内才吃事件，否则放行给列表滚动
    func consume(_ event: NSEvent) -> Bool {
        guard panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) else { return false }
        switch event.type {
        case .scrollWheel:
            let sensitivity: CGFloat = event.modifierFlags.contains(.command) ? 0.0015 : 0.0045
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return false }
            model.zoom.zoom(by: exp(delta * sensitivity))
        case .magnify:
            let m = event.magnification
            guard m != 0 else { return false }
            model.zoom.zoom(by: 1 + m)
        default:
            return false
        }
        return true
    }

    func resetZoom() {
        model.zoom.reset()
    }

    // MARK: 定位

    /// 贴在主面板旁边：右边放得下就放右边，否则翻到左边
    func reposition() {
        guard let anchor = anchorWindow else { return }
        let size = panel.frame.size
        let anchorFrame = anchor.frame
        let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
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
