import Foundation

/// 拼音索引。中文搜索的体验全靠它：
/// 输入 "dolmo" 或 "dl" 之类都能命中，不需要切换输入法。
enum Pinyin {
    /// 只对前 N 个字符做索引，长文本做全量转换会拖慢捕获
    private static let maxLength = 200

    static func index(for text: String) -> String {
        guard !text.isEmpty else { return "" }
        let source = String(text.prefix(maxLength))
        let mutable = NSMutableString(string: source)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
    }

    /// 判断是否命中。中文按子串，拼音按"首字母缩写或连续片段"
    static func matches(text: String, pinyinIndex: String?, query: String) -> Bool {
        if text.localizedCaseInsensitiveContains(query) { return true }
        guard let pinyin = pinyinIndex, !pinyin.isEmpty else { return false }
        if pinyin.contains(query) { return true }
        // 索引是 "ni hao" 这种带空格的形式，用户输入 "nihao" 也要命中
        if compact(of: pinyin).contains(query) { return true }
        return initials(of: pinyin).contains(query)
    }

    /// 去掉空格与非字母，用来匹配连续输入的拼音（"ni hao" -> "nihao"）
    static func compact(of pinyin: String) -> String {
        String(pinyin.unicodeScalars.filter { $0.value >= 97 && $0.value <= 122 }.map(Character.init))
    }

    /// 取每个拼音音节的首字母，例如 "dolmo paste" -> "dp"
    /// 这里按空格/非字母切分，够用且零依赖
    static func initials(of pinyin: String) -> String {
        var result = ""
        var expectInitial = true
        for scalar in pinyin.unicodeScalars {
            let isLetter = (scalar.value >= 97 && scalar.value <= 122)
            if isLetter {
                if expectInitial {
                    result.append(Character(scalar))
                    expectInitial = false
                }
            } else {
                expectInitial = true
            }
        }
        return result
    }
}
