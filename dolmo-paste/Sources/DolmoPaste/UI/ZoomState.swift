import AppKit
import SwiftUI

/// 唯一的图片几何模型。100% = 一个图像像素对应一个屏幕物理像素。
/// Fit 随容器变化；Actual / Custom 保持真实倍率，不随窗口 resize 漂移。
struct ZoomState {
    enum Mode: Equatable { case fit, actual, custom }
    private(set) var mode: Mode = .fit
    private(set) var containerSize: CGSize = .zero
    private(set) var pixelSize: CGSize = .zero
    private(set) var backingScale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private var customRatio: CGFloat = 1

    var hasGeometry: Bool {
        pixelSize.width > 0 && pixelSize.height > 0 && containerSize.width > 0 && containerSize.height > 0
    }
    private var fitRatio: CGFloat {
        guard hasGeometry else { return 1 }
        return min(containerSize.width / pixelSize.width, containerSize.height / pixelSize.height) * backingScale
    }
    var actualRatio: CGFloat {
        switch mode {
        case .fit: return fitRatio
        case .actual: return 1
        case .custom: return customRatio
        }
    }
    /// 兼容相对适应倍率；绘制本身只用 imageRect，禁止另乘 scaledToFit。
    var scale: CGFloat { actualRatio / fitRatio }
    var isZoomed: Bool { mode != .fit }
    var isActualSize: Bool { hasGeometry && abs(actualRatio - 1) < 0.000001 }
    var displaySize: CGSize {
        CGSize(width: pixelSize.width * actualRatio / backingScale,
               height: pixelSize.height * actualRatio / backingScale)
    }
    var imageRect: CGRect {
        let size = displaySize
        var origin = CGPoint(x: (containerSize.width - size.width) / 2 + offset.width,
                             y: (containerSize.height - size.height) / 2 + offset.height)
        if isActualSize {
            origin.x = (origin.x * backingScale).rounded() / backingScale
            origin.y = (origin.y * backingScale).rounded() / backingScale
        }
        return CGRect(origin: origin, size: size)
    }
    var canPan: Bool {
        hasGeometry && (displaySize.width > containerSize.width + 0.5 || displaySize.height > containerSize.height + 0.5)
    }
    var percentText: String {
        guard hasGeometry, actualRatio.isFinite else { return "—" }
        return "\(Int((actualRatio * 100).rounded()))%"
    }

    mutating func setImagePixels(_ size: CGSize) {
        pixelSize = size
        reset()
    }
    mutating func reset() {
        mode = .fit
        offset = .zero
    }
    mutating func setContainer(_ size: CGSize, backingScale: CGFloat? = nil) {
        containerSize = size
        if let backingScale, backingScale.isFinite, backingScale > 0 { self.backingScale = backingScale }
        clampOffset()
    }
    /// 捏合 / 滚轮：以 anchor（画布坐标，默认中心）为不动点缩放
    mutating func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        guard hasGeometry, factor.isFinite, factor > 0, abs(factor - 1) > 1e-8 else { return }
        let next = min(max(actualRatio * factor, min(0.01, fitRatio)), max(32, fitRatio))
        apply(ratio: next, mode: .custom, anchor: anchor)
    }
    mutating func zoomToActual(anchor: CGPoint? = nil) {
        guard hasGeometry else { return }
        apply(ratio: 1, mode: .actual, anchor: anchor)
    }

    /// 双击放大的目标倍率：原图比窗口大得多（1:1 至少是适应的 1.5 倍）→ 进 1:1，像素清晰；
    /// 否则（小图 / 窗口已经很大，1:1 不比适应大多少甚至更小）→ 放大到适应的 2 倍，保证双击一定是"变大"
    var doubleClickTarget: CGFloat { fitRatio <= 1 / 1.5 ? 1 : min(fitRatio * 2, 32) }

    /// 双击 / 空格：只看当前是不是「适应」。
    /// 适应 → 以点击位置为中心放大；其余任何状态（1:1、捏合过的任意倍率）→ 回适应。
    /// 规则只有这一条，与之前怎么缩放、窗口拖成多大无关。
    mutating func toggleZoom(at anchor: CGPoint? = nil) {
        guard hasGeometry else { return }
        guard mode == .fit else { reset(); return }
        let target = doubleClickTarget
        if abs(target - 1) < 1e-9 {
            apply(ratio: 1, mode: .actual, anchor: anchor)
        } else {
            apply(ratio: target, mode: .custom, anchor: anchor)
        }
    }
    mutating func toggleActual() { toggleZoom(at: nil) }

    /// 切换倍率，保持 anchor 下面那个图像点不动
    private mutating func apply(ratio: CGFloat, mode newMode: Mode, anchor: CGPoint?) {
        let oldSize = displaySize
        let oldOrigin = CGPoint(x: (containerSize.width - oldSize.width) / 2 + offset.width,
                                y: (containerSize.height - oldSize.height) / 2 + offset.height)
        let p = anchor ?? CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        // 点在白边上时按最近的图片边缘算，避免放大后跑出一片空白
        let u = CGPoint(x: min(max((p.x - oldOrigin.x) / max(oldSize.width, 1e-9), 0), 1),
                        y: min(max((p.y - oldOrigin.y) / max(oldSize.height, 1e-9), 0), 1))
        mode = newMode
        if newMode == .custom { customRatio = ratio }
        let newSize = displaySize
        offset = CGSize(width: p.x - u.x * newSize.width - (containerSize.width - newSize.width) / 2,
                        height: p.y - u.y * newSize.height - (containerSize.height - newSize.height) / 2)
        clampOffset()
    }
    mutating func pan(by delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        clampOffset()
    }
    private mutating func clampOffset() {
        let size = displaySize
        let maxX = max(0, (size.width - containerSize.width) / 2)
        let maxY = max(0, (size.height - containerSize.height) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }
}

/// NSImage.size 是 points，可能来自 DPI 元数据；不能拿它当源像素。
enum ImagePixelGeometry {
    static func size(of image: NSImage?) -> CGSize {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .zero }
        return CGSize(width: cg.width, height: cg.height)
    }
}

/// 两个查看器共用同一 AppKit 画布：绘制、命中、事件使用相同的 imageRect。
/// 窗口移动交给 performDrag，而不是用移动中的 SwiftUI local translation 回写窗口。
struct NativeImageCanvas: NSViewRepresentable {
    let image: NSImage?
    @Binding var zoom: ZoomState
    var movesWindow = false
    var onInteraction: () -> Void = {}
    var onWindowDrag: () -> Void = {}

    func makeNSView(context: Context) -> ImageCanvasView { ImageCanvasView() }
    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.image = image
        view.state = $zoom
        view.movesWindow = movesWindow
        view.onInteraction = onInteraction
        view.onWindowDrag = onWindowDrag
        view.needsDisplay = true
        // SwiftUI 更新期间不发布状态；下一轮同步 AppKit 实际 bounds。
        view.scheduleGeometryUpdate()
    }
}

final class ImageCanvasView: NSView {
    var image: NSImage?
    var state: Binding<ZoomState>?
    var movesWindow = false
    var onInteraction: () -> Void = {}
    var onWindowDrag: () -> Void = {}
    private var geometryScheduled = false
    private var lastPanPoint: CGPoint?
    private var windowDragStart: NSEvent?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var geometry: ZoomState {
        var value = state?.wrappedValue ?? ZoomState()
        value.setContainer(bounds.size, backingScale: window?.backingScaleFactor ?? 1)
        return value
    }
    func scheduleGeometryUpdate() {
        guard !geometryScheduled else { return }
        geometryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryScheduled = false
            self.syncGeometry()
        }
    }
    private func syncGeometry() {
        guard let state else { return }
        let old = state.wrappedValue
        let next = geometry
        if old.containerSize != next.containerSize || old.backingScale != next.backingScale || old.offset != next.offset {
            state.wrappedValue = next
        }
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        scheduleGeometryUpdate()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleGeometryUpdate()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleGeometryUpdate()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { window?.makeKey() }
    // MARK: 双击过渡动画：状态立即落到终值（命中/倍率都按终值），只有绘制从旧矩形插值过去
    private var animFrom: CGRect?
    private var animStart: TimeInterval = 0
    private var animTimer: Timer?
    private static let animDuration: TimeInterval = 0.18
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func animate(from rect: CGRect) {
        animFrom = rect
        animStart = now
        animTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if self.now - self.animStart >= Self.animDuration {
                    self.animFrom = nil
                    timer.invalidate()
                }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    /// 当前屏幕上实际画出来的矩形（动画中是插值）
    private var drawnRect: CGRect {
        let target = geometry.imageRect
        guard let from = animFrom else { return target }
        let t = min(max((now - animStart) / Self.animDuration, 0), 1)
        let e = CGFloat(1 - pow(1 - t, 3))   // easeOutCubic
        return CGRect(x: from.minX + (target.minX - from.minX) * e,
                      y: from.minY + (target.minY - from.minY) * e,
                      width: from.width + (target.width - from.width) * e,
                      height: from.height + (target.height - from.height) * e)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let crisp = animFrom == nil && geometry.isActualSize
        NSGraphicsContext.current?.imageInterpolation = crisp ? .none : .high
        image.draw(in: drawnRect, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }

    /// 鼠标当前位置（画布坐标）。全局监听收到的事件不属于本窗口，不能用 event.locationInWindow
    private var mouseInCanvas: CGPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        syncGeometry()
        window?.makeKey()
        lastPanPoint = nil
        windowDragStart = nil
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            onInteraction()
            let before = drawnRect
            var value = geometry
            value.toggleZoom(at: point)
            state?.wrappedValue = value
            animate(from: before)
            needsDisplay = true
        } else if event.clickCount > 2 {
            // 三击及以上不再切换，避免双击后多点一下又切回去
            return
        } else if geometry.canPan && geometry.imageRect.contains(point) {
            onInteraction()
            lastPanPoint = point
        } else if movesWindow {
            windowDragStart = event
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if let start = windowDragStart {
            let dx = event.locationInWindow.x - start.locationInWindow.x
            let dy = event.locationInWindow.y - start.locationInWindow.y
            guard hypot(dx, dy) >= 3 else { return }
            windowDragStart = nil
            onWindowDrag()
            window?.performDrag(with: start)
            return
        }
        guard let previous = lastPanPoint else { return }
        animFrom = nil
        let point = convert(event.locationInWindow, from: nil)
        var value = geometry
        value.pan(by: CGSize(width: point.x - previous.x, height: point.y - previous.y))
        state?.wrappedValue = value
        lastPanPoint = point
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { lastPanPoint = nil; windowDragStart = nil }
    @discardableResult func consumeZoom(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
        return applyZoom(event)
    }
    @discardableResult func applyZoom(_ event: NSEvent) -> Bool {
        let factor: CGFloat
        switch event.type {
        case .scrollWheel:
            guard event.scrollingDeltaY != 0 else { return false }
            factor = exp(event.scrollingDeltaY * (event.modifierFlags.contains(.command) ? 0.0015 : 0.0045))
        case .magnify:
            guard event.magnification != 0 else { return false }
            factor = 1 + event.magnification
        default: return false
        }
        onInteraction()
        animFrom = nil
        var value = geometry
        value.zoom(by: factor, anchor: mouseInCanvas)
        state?.wrappedValue = value
        needsDisplay = true
        return true
    }
    override func scrollWheel(with event: NSEvent) { if !consumeZoom(event) { super.scrollWheel(with: event) } }
    override func magnify(with event: NSEvent) { if !consumeZoom(event) { super.magnify(with: event) } }
}

/// 信息行全宽命中，包括 Spacer 留白；系统窗口自己追踪屏幕坐标。
struct NativeWindowDragArea: NSViewRepresentable {
    var onDrag: () -> Void
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) { view.onDrag = onDrag }
}
final class WindowDragView: NSView {
    var onDrag: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var start: NSEvent?
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = event
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, hypot(event.locationInWindow.x - start.locationInWindow.x,
                               event.locationInWindow.y - start.locationInWindow.y) >= 3 else { return }
        self.start = nil
        onDrag()
        window?.performDrag(with: start)
    }
    override func mouseUp(with event: NSEvent) { start = nil }
}
