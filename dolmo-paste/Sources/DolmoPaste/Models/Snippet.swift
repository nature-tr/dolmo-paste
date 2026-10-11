import Foundation
import SwiftData

/// 常用片段。和剪贴板历史分开：历史是"你复制过什么"，片段是"你总要粘什么"。
/// 不会被淘汰，支持变量展开。
@Model
final class Snippet {
    @Attribute(.unique) var id: UUID = UUID()
    /// 列表里显示的名字
    var title: String = ""
    /// 实际粘出去的内容，支持 {{变量}}
    var content: String = ""
    /// 触发词：面板里打这个词能直接命中
    var keyword: String = ""
    var createdAt: Date = Date()
    var useCount: Int = 0
    var lastUsedAt: Date?

    init(title: String = "", content: String = "", keyword: String = "") {
        self.id = UUID()
        self.title = title
        self.content = content
        self.keyword = keyword
        self.createdAt = Date()
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let first = content.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "未命名片段" : String(first.prefix(40))
    }

    /// 内容的第一行，压去首尾空白
    var previewLine: String {
        let line = content.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 浮窗列表的第二行：有触发词就先放触发词，再放内容首行
    var panelDetail: String {
        var parts: [String] = []
        if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(keyword) }
        let line = previewLine
        if !line.isEmpty { parts.append(line) }
        return parts.isEmpty ? "（空内容）" : parts.joined(separator: " · ")
    }
}

/// {{变量}} 展开。放在 @MainActor 类型之外，纯函数、可直接测试。
enum SnippetExpander {
    /// 支持的变量，设置页里要列给用户看
    static let supportedVariables = ["{{date}}", "{{time}}", "{{datetime}}", "{{year}}", "{{clipboard}}"]

    static func expand(_ content: String, clipboard: String? = nil) -> String {
        guard content.contains("{{") else { return content }
        let now = Date()
        let calendar = Calendar.current
        let year = String(calendar.component(.year, from: now))
        var result = content
        result = result.replacingOccurrences(of: "{{date}}", with: formatted(now, "yyyy-MM-dd"))
        result = result.replacingOccurrences(of: "{{time}}", with: formatted(now, "HH:mm"))
        result = result.replacingOccurrences(of: "{{datetime}}", with: formatted(now, "yyyy-MM-dd HH:mm"))
        result = result.replacingOccurrences(of: "{{year}}", with: year)
        if let clipboard {
            result = result.replacingOccurrences(of: "{{clipboard}}", with: clipboard)
        }
        return result
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
