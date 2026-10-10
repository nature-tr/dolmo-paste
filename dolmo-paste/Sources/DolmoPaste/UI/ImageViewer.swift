import AppKit
import Carbon
import SwiftUI

// MARK: - 状态

/// 大图查看器的状态与事件处理。
/// 缩放相关的事件（滚轮 / 触控板捏合）走 NSEvent 本地监听，不走 SwiftUI 手势：
/// SwiftUI 在 macOS 上没有 scrollWheel 手势，捏合手势的触发也不稳定。
@MainActor
final class ImageViewerModel: ObservableObject {
    @Published private(set) var image: NSImage?
    /// 尺寸 / 来源 App，窗口复用时也要跟着换，所以放状态里
    @Published private(set) var subtitle: String = ""
    @Published var zoom = ZoomState()

    var onClose: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?

    private var monitor: Any?
    private let minScale: CGFloat = 0.1
    private let maxScale: CGFloat = 32

    // MARK: 加载

    func load(item: ClipItem, imagesDirectory: URL) {
        var loaded: NSImage?
        // 优先读落盘原图，缩略图只有 400px，放大就糊了
        if let name = item.imageFileName {
            loaded = NSImage(contentsOf: imagesDirectory.appendingPathComponent(name))
        }
        if loaded == nil, let data = item.thumbnailData {
            loaded = NSImage(data: data)
        }
        image = loaded
        zoom.pixelSize = loaded?.size ?? .zero

        var parts = ["\(item.imageWidth) × \(item.imageHeight)"]
        if let app = item.sourceAppName, !app.isEmpty { parts.append("来自 \(app)") }
        if item.imageTruncated { parts.append("原图过大，已存缩略图") }
        subtitle = parts.joined(separator: " · ")
    }

    func reset() {
        zoom.reset()
    }

    // MARK: 事件

    func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown]) { [weak self] event in
            // 监听器回调不在 MainActor 上，状态更新必须跳回去
            Task { @MainActor in self?.handle(event) }
            return nil
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            // 鼠标滚轮和触控板双指滑动都走这里：上滑放大
            // ⌘ 按下时步长调小，用来做精细调整
            let sensitivity: CGFloat = event.modifierFlags.contains(.command) ? 0.0015 : 0.0045
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            zoom.zoom(by: exp(delta * sensitivity))

        case .magnify:
            // 触控板双指捏合
            let m = event.magnification
            guard m != 0 else { return }
            zoom.zoom(by: 1 + m)

        case .keyDown:
            handleKey(event)

        default:
            break
        }
    }

    private func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.command) {
            switch chars.lowercased() {
            case "0":
                zoom.reset()
            case "+", "=":
                zoom.zoom(by: 1.25)
            case "-":
                zoom.zoom(by: 1 / 1.25)
            case "w":
                onClose?()
            default:
                break
            }
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            onClose?()
        case kVK_Return:
            onPaste?()
        case kVK_Space:
            // 空格在查看器里没有输入框，直接 1:1 / 适应 切换
            if zoom.isZoomed { zoom.reset() } else { zoom.zoomToActual() }
        default:
            break
        }
    }
}

// MARK: - 视图

struct ImageViewerView: View {
    @ObservedObject var model: ImageViewerModel
    let onClose: () -> Void

    @State private var dragStart: CGSize = .zero

    var body: some View {
        ZStack {
            // 图片查看器用深色底，颜色才不会被界面色带偏
            Rectangle().fill(Color.black.opacity(0.86))

            GeometryReader { geo in
                imageLayer
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { model.zoom.containerSize = geo.size }
                    .onChange(of: geo.size) { _, new in model.zoom.containerSize = new }
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
        }
    }

    private var imageLayer: some View {
        Group {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(model.zoom.scale, anchor: .center)
                    .offset(model.zoom.offset)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                model.zoom.pan(by: CGSize(
                                    width: value.translation.width - dragStart.width,
                                    height: value.translation.height - dragStart.height
                                ))
                                dragStart = value.translation
                            }
                            .onEnded { _ in dragStart = .zero }
                    )
                    // 双击在「适应窗口」和「原图 1:1」之间切换
                    .onTapGesture(count: 2) {
                        if model.zoom.isZoomed { model.zoom.reset() } else { model.zoom.zoomToActual() }
                    }
                    .animation(.easeOut(duration: 0.12), value: model.zoom.scale)
            } else {
                Text("图片已失效")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text(model.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Spacer(minLength: 0)
            ViewerIconButton(systemName: "xmark") { onClose() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            ViewerIconButton(systemName: "minus.magnifyingglass") { model.zoom.zoom(by: 1 / 1.25) }

            Text(model.zoom.percentText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 52)
                .contentTransition(.numericText())

            ViewerIconButton(systemName: "plus.magnifyingglass") { model.zoom.zoom(by: 1.25) }

            ViewerDivider()

            ViewerTextButton("适应") { model.zoom.reset() }
            ViewerTextButton("1:1") { model.zoom.zoomToActual() }

            Spacer(minLength: 8)

            Text("滚轮 / 双指缩放 · 拖拽移动 · 双击 1:1 · Esc 关闭")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))

            Spacer(minLength: 8)

            ViewerTextButton("复制") { model.onCopy?() }
            ViewerTextButton("粘贴 ⏎") { model.onPaste?() }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.bar)
    }
}

private struct ViewerIconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .white : .white.opacity(0.72))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ViewerTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .white : .white.opacity(0.78))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.16) : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ViewerDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 16)
    }
}

// MARK: - 窗口

@MainActor
final class ImageViewerController: NSObject, NSWindowDelegate {
    private let model = ImageViewerModel()
    private var window: NSWindow?

    var onClose: (() -> Void)?
    var onPaste: ((ClipItem) -> Void)?
    var onCopy: ((ClipItem) -> Void)?
    private var currentItem: ClipItem?

    var isVisible: Bool { window?.isVisible == true }

    func show(item: ClipItem, imagesDirectory: URL) {
        currentItem = item
        model.load(item: item, imagesDirectory: imagesDirectory)
        model.onClose = { [weak self] in self?.close() }
        model.onPaste = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onPaste?(item)
        }
        model.onCopy = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onCopy?(item)
        }

        if window == nil { makeWindow() }
        guard let window else { return }

        model.reset()
        window.center()

        // 和主窗口同样的问题：菜单栏应用是 .accessory，窗口不会被 activate 带到最前
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        model.installMonitor()
    }

    func close() {
        model.removeMonitor()
        window?.orderOut(nil)
        currentItem = nil
        onClose?()
    }

    private func makeWindow() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: visible.width * 0.72, height: visible.height * 0.78)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "图片预览"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)
        window.delegate = self

        let view = ImageViewerView(model: model) { [weak self] in
            self?.close()
        }
        window.contentView = NSHostingView(rootView: view)
        self.window = window
    }

    /// 点系统红绿灯关闭
    func windowWillClose(_ notification: Notification) {
        close()
    }
}
