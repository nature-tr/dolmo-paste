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

    /// 把历史项写回剪贴板。
    /// - Returns: 是否按预期类型写成功。文件类在**原文件已失效**时返回 false，
    ///   调用方据此提示用户，而不是让用户对着一个写不进去的剪贴板发懵。
    @discardableResult
    static func writeToPasteboard(_ item: ClipItem, plainTextOnly: Bool, imagesDirectory: URL) -> Bool {
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
            return image != nil

        case .file:
            // 原文件可能已被删除或移动：写进去的引用粘不出来，静默失败最难受。
            // 先过滤掉不可达的，全部失效时降级成文件名文本，并如实告诉调用方
            let reachable = item.filePaths
                .map { URL(fileURLWithPath: $0) }
                .filter { (try? $0.checkResourceIsReachable()) == true }
            if !reachable.isEmpty {
                pasteboard.writeObjects(reachable.map { $0 as NSURL })
                return reachable.count == item.filePaths.count
            }
            let names = item.fileNames.joined(separator: "\n")
            pasteboard.setString(names.isEmpty ? item.textContent : names, forType: .string)
            return false

        default:
            pasteboard.setString(item.textContent, forType: .string)
            if !plainTextOnly, let rtf = item.rtfData {
                pasteboard.setData(rtf, forType: .rtf)
            }
            return true
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
