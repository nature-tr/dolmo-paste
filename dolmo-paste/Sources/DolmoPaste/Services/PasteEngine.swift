import AppKit
import Carbon

/// 粘贴执行器。
/// 两步：把历史项写回系统剪贴板 → 模拟 ⌘V（需要辅助功能权限）。
/// 没有权限时退化成"只写回剪贴板"，用户自己按 ⌘V。
enum PasteEngine {
    static func isTrusted(prompt: Bool = false) -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func writeToPasteboard(_ item: ClipItem, plainTextOnly: Bool, imagesDirectory: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .image:
            var image: NSImage?
            if let fileName = item.imageFileName {
                image = NSImage(contentsOf: imagesDirectory.appendingPathComponent(fileName))
            }
            if image == nil, let thumbnail = item.thumbnailData {
                image = NSImage(data: thumbnail)
            }
            if let image {
                pasteboard.writeObjects([image])
            } else {
                pasteboard.setString(item.textContent, forType: .string)
            }

        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls.map { $0 as NSURL })
            } else {
                pasteboard.setString(item.textContent, forType: .string)
            }

        default:
            pasteboard.setString(item.textContent, forType: .string)
            if !plainTextOnly, let rtf = item.rtfData {
                pasteboard.setData(rtf, forType: .rtf)
            }
        }
    }

    /// 模拟 ⌘V。必须在面板已关闭、原 App 重新拿到焦点之后调用。
    static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
