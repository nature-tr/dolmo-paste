import AppKit

/// 轻量提示浮层。主要用于两处：
/// 1. 没有辅助功能权限时，告知"已复制，请按 ⌘V"
/// 2. 关键操作的结果反馈
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, duration: TimeInterval = 2.4) {
        let target: NSPanel
        if let existing = panel {
            target = existing
        } else {
            let created = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isOpaque = false
            created.backgroundColor = .clear
            created.level = .statusBar
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.ignoresMouseEvents = true
            created.hasShadow = false
            panel = created
            target = created
        }

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        let width = label.intrinsicContentSize.width + 40
        let height: CGFloat = 42
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        container.layer?.cornerRadius = 12
        label.frame = NSRect(
            x: (width - label.intrinsicContentSize.width) / 2,
            y: (height - label.intrinsicContentSize.height) / 2,
            width: label.intrinsicContentSize.width,
            height: label.intrinsicContentSize.height
        )
        container.addSubview(label)
        target.contentView = container

        // 主屏底部居中
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        target.setFrame(
            NSRect(
                x: screen.midX - width / 2,
                y: screen.minY + 56,
                width: width,
                height: height
            ),
            display: true
        )
        target.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}
