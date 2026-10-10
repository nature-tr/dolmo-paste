import AppKit
import Carbon
import SwiftUI

// MARK: - 状态

/// 大图查看器的状态与键盘事件处理；图片交互交给共用 AppKit 画布。
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
        zoom.setImagePixels(ImagePixelGeometry.size(of: loaded))

        var parts = ["\(item.imageWidth) × \(item.imageHeight)"]
        if let app = item.sourceAppName, !app.isEmpty { parts.append("来自 \(app)") }
        if item.imageTruncated { parts.append("原图过大，已存缩略图") }
        subtitle = parts.joined(separator: " · ")
    }

    func reset() {
        zoom.reset()
    }

    // MARK: 事件

    func installMonitor(in window: NSWindow) {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            // AppKit 本地监听在主线程同步执行，必须当场决定是否消费事件。
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window,
                      event.window === window, window.isVisible, window.isKeyWindow else { return false }
                return self.handleKey(event)
            }
            return consumed ? nil : event
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

        if flags.contains(.command) {
            guard flags == .command || (flags == [.command, .shift] && (chars == "+" || chars == "=")) else {
                return false
            }
            switch chars {
            case "0":
                zoom.reset()
            case "+", "=":
                zoom.zoom(by: 1.25)
            case "-":
                zoom.zoom(by: 1 / 1.25)
            case "w":
                onClose?()
            case "c":
                onCopy?()
            default:
                return false
            }
            return true
        }

        guard flags.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            onClose?()
        case kVK_Return:
            onPaste?()
        case kVK_Space:
            zoom.toggleActual()
        default:
            return false
        }
        return true
    }
}

// MARK: - 视图

@MainActor
struct ImageViewerView: View {
    @ObservedObject var model: ImageViewerModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // 图片查看器用深色底，颜色才不会被界面色带偏
            Rectangle().fill(Color.black.opacity(0.86))

            imageLayer

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
        }
    }

    private var imageLayer: some View {
        ZStack {
            NativeImageCanvas(image: model.image, zoom: $model.zoom)
            if model.image == nil {
                Text("图片已失效")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .allowsHitTesting(false)
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

            Text("滚轮 / 双指缩放 · 拖拽移动 · 双击放大 / 还原 · Esc 关闭")
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
    private var generation = 0

    var onClose: (() -> Void)?
    var onPaste: ((ClipItem) -> Void)?
    var onCopy: ((ClipItem) -> Void)?
    private var currentItem: ClipItem?

    var isVisible: Bool { window?.isVisible == true }

    func show(item: ClipItem, imagesDirectory: URL) {
        generation &+= 1
        let showGeneration = generation
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
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  self.generation == showGeneration, self.window === window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        model.installMonitor(in: window)
    }

    func close() {
        generation &+= 1
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
