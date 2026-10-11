import AppKit

/// 捕获内容的识别与转换。放在 @MainActor 类型之外，纯函数、可直接测试。
enum ContentHeuristics {
    /// 单条文本最多留这么多字节（1 MB），超出只存前缀
    static let maxTextBytes = 1_048_576

    static func capped(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var cut = text
        while cut.utf8.count > maxTextBytes { cut = String(cut.dropLast(max(1, cut.count / 8))) }
        return cut + "\n…（内容过大，只保留了前 1 MB）"
    }

    /// 识别纯 hex 颜色值（#RGB / #RRGGBB / #RRGGBBAA），统一成大写 #RRGGBB。
    /// 只认"整串就是一个颜色"的情况，避免把正文里带 # 的句子误判成颜色
    static func normalizedHex(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = String(trimmed.dropFirst())
        guard body.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch body.count {
        case 3: return "#" + body.map { "\($0)\($0)" }.joined().uppercased()
        case 6: return "#" + body.uppercased()
        case 8: return "#" + String(body.prefix(6)).uppercased()
        default: return nil
        }
    }

    // macOS 上要用带 documentType 的初始化方法，直接传 html 的那个只有 iOS 有
    private static func attributed(fromHTML data: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: data,
            // 必须显式指定编码：默认会把 UTF-8 的中文按其他编码解，直接变乱码
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    /// HTML → 纯文本
    static func plainText(fromHTML data: Data) -> String? {
        guard let attributed = attributed(fromHTML: data) else { return nil }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : attributed.string
    }

    /// HTML → RTF，粘贴时能还原排版
    static func rtf(fromHTML data: Data) -> Data? {
        guard let attributed = attributed(fromHTML: data) else { return nil }
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length))
    }
}
