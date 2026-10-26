import AppKit
import Carbon

/// 粘贴执行器：只负责把历史项写回系统剪贴板。
///
/// ⚠️ 这里**故意不模拟 ⌘V**。App Store 审核 Guideline 2.4.5 明确规定：
/// 辅助功能（Accessibility）只能用于增强无障碍，不能用来实现「自动粘贴」。
/// 我们的 1.0 就是因为这个被拒（原文："the app uses Accessibility features to
/// enable paste function"）。所以选中条目后只写剪贴板，由用户自己按 ⌘V。
/// 不要再把 CGEvent.post 加回来——加了就上不了架。
enum PasteEngine {

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
