import AppKit
import Carbon
import SwiftUI

/// 快捷键录入控件：点一下进入录制态，按下组合键即生效。
///
/// 用 AppKit 自己画而不是 SwiftUI 的 `.onKeyPress`：
/// SwiftUI 在 TextField 之外的场景拿不到稳定的 modifierFlags，且修饰键单独按下时不产生事件。
struct HotkeyRecorder: NSViewRepresentable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// 返回 false 表示这个组合没注册上（被占用），调用方负责提示
    var onCommit: (UInt32, UInt32) -> Bool

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ view: HotkeyRecorderView, context: Context) {
        view.keyCode = keyCode
        view.modifiers = modifiers
        // 每次 SwiftUI 刷新都会重建闭包捕获，必须重挂，否则回调里拿到的是旧值
        view.onCommit = onCommit
    }
}

final class HotkeyRecorderView: NSView {
    var keyCode: UInt32 = UInt32(kVK_ANSI_V) { didSet { needsDisplay = true } }
    var modifiers: UInt32 = UInt32(cmdKey | shiftKey) { didSet { needsDisplay = true } }
    var onCommit: ((UInt32, UInt32) -> Bool)?

    private var isRecording = false { didSet { needsDisplay = true } }
    /// 注册失败时闪一下红框，光靠文字提示太安静
    private var showsFailure = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let click = NSClickGestureRecognizer(target: self, action: #selector(beginRecording))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    @objc private func beginRecording() {
        window?.makeFirstResponder(self)
        isRecording = true
        showsFailure = false
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Esc 取消，不改任何东西
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }
        let mods = HotkeyDisplay.carbonModifiers(from: event.modifierFlags)
        // 单独按修饰键时 modifierFlags 还没带上它自己，跳过等真正的键
        guard mods != 0 else { return }

        isRecording = false
        window?.makeFirstResponder(nil)
        let ok = onCommit?(UInt32(event.keyCode), mods) ?? false
        if !ok {
            showsFailure = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.showsFailure = false }
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        path.fill()

        if showsFailure {
            NSColor.systemRed.setStroke()
        } else if isRecording {
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = isRecording || showsFailure ? 1.5 : 0.5
        path.stroke()

        let text = isRecording ? "按下快捷键…" : HotkeyDisplay.string(keyCode: keyCode, modifiers: modifiers)
        let color: NSColor = isRecording ? .controlAccentColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
