import AppKit
import Carbon

/// 粘贴执行器：把历史项写回系统剪贴板，拿到授权后再合成一次 ⌘V。
///
/// ⚠️ 关于「辅助功能」，这里的边界是硬约束，改之前先读完这段：
///
/// · **只查，不读**。授权状态只用 `AXIsProcessTrusted()` 问一句，
///   全程不创建 AXUIElement，不遍历别的 App 的界面树，不读焦点控件和它的坐标。
///   1.0 就是因为用 AX 读了焦点输入框的位置来给浮窗贴边，被审核判成
///   「accessibility for non-accessibility purposes」拒掉。
///   浮窗定位现在一律用鼠标位置（见 ClipPanelController.position(near:)）。
/// · **只发，不收**。这里唯一的动作是 post 一个 ⌘V 按键事件：不装事件监听器，
///   不录制键盘输入，不往任何 App 里注入文本。
/// · 没有授权时整个模块退化成「只写剪贴板」，功能照常，用户自己按 ⌘V。
///
/// 这套形状和 Mac App Store 上在售的 Maccy（org.p0deje.Maccy）一致：
/// 它同样是沙盒 + CGEvent 合成 ⌘V，且从不读别的 App 的界面。
enum PasteEngine {

    // MARK: - 授权

    /// 是否已获得辅助功能授权。**纯查询**：不会弹系统对话框，也不会读任何界面元素
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    /// 只是让系统设置跳到那一页，本身不涉及任何辅助功能调用
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - 合成 ⌘V

    /// 合成一次 ⌘V。
    ///
    /// 调用前必须已经 `hide()` 把焦点还给用户原来那个 App，
    /// 否则这个按键会打在我们自己的浮窗上。
    /// 归还焦点是异步的，所以这里等 frontmost 真正换掉再发（最多约 0.3 秒）。
    static func postCommandV() {
        attemptPost(remaining: 8)
    }

    private static func attemptPost(remaining: Int) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == selfPID, remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                attemptPost(remaining: remaining - 1)
            }
            return
        }
        postCommandVNow()
    }

    private static func postCommandVNow() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - 提示文案

    /// 没授权时的提示语。第一次带上「去哪儿开」，之后只说「按 ⌘V」。
    /// 抽成纯函数是为了能测：这条提示每次唤起都会走一遍，
    /// 一旦判断写反，就变成每粘一次念一遍「设置 → 通用」。
    static func manualPasteHint(_ base: String, alreadyShown: Bool) -> String {
        alreadyShown ? base : base + "。想要选完直接粘贴？设置 → 通用"
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

    /// 把多条历史拼成一段写回剪贴板（合并粘贴）。
    /// 图片/文件没法拼，写它们的文件名或占位；至少不会让你看着空剪贴板发懵。
    @discardableResult
    static func writeMergedToPasteboard(_ items: [ClipItem], imagesDirectory: URL, separator: String = "\n") -> Bool {
        guard !items.isEmpty else { return false }
        if items.count == 1 {
            return writeToPasteboard(items[0], plainTextOnly: false, imagesDirectory: imagesDirectory)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var parts: [String] = []
        var image: NSImage?
        for item in items {
            switch item.kind {
            case .image:
                if image == nil {
                    if let name = item.imageFileName {
                        image = NSImage(contentsOf: imagesDirectory.appendingPathComponent(name))
                    }
                    if image == nil, let thumbnail = item.thumbnailData { image = NSImage(data: thumbnail) }
                }
                parts.append(item.textContent.isEmpty ? "[图片 \(item.imageWidth)×\(item.imageHeight)]" : item.textContent)
            case .file:
                parts.append(item.fileNames.isEmpty ? item.textContent : item.fileNames.joined(separator: ", "))
            default:
                parts.append(item.textContent)
            }
        }

        let merged = parts.filter { !$0.isEmpty }.joined(separator: separator)
        guard !merged.isEmpty else {
            if let image { pasteboard.writeObjects([image]); return true }
            return false
        }
        pasteboard.setString(merged, forType: .string)
        // 拼好的内容里还夹着图片的话，附在后面，目标 App 会按自己的规则选一个用
        if let image { pasteboard.writeObjects([image]) }
        return true
    }

    /// 片段用：展开后的文本直接写回剪贴板
    static func writeStringToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
