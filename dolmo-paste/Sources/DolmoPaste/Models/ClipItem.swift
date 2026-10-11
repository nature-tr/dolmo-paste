import Foundation
import SwiftData

enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case text
    case image
    case file
    case color

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        case .color: return "颜色"
        }
    }
}

/// 一条剪贴板记录。
/// 图片一律落盘，数据库里只存路径，避免库无限膨胀。
@Model
final class ClipItem {
    @Attribute(.unique) var id: UUID = UUID()
    var kind: ClipKind = ClipKind.text
    /// kind 的镜像，只为查询用。
    /// SwiftData 的 #Predicate 里没法用 enum：`$0.kind == ClipKind.image` 编译不过
    /// （"key path cannot refer to enum case"），`$0.kind.rawValue` 运行时崩（schema 里
    /// 没有这一层 key path），捕获成局部常量虽然能编译但 fetchCount 恒返回 0——
    /// enum 在库里是 Codable 存储，SQL 比不了。所以另外存一个 Bool 当查询键。
    /// kind 才是真值，这个只是索引；两者在 init 里同步，kind 之后不会再变
    var isImage: Bool = false

    /// 纯文本，用于搜索、预览和纯文本粘贴
    var textContent: String = ""
    var rtfData: Data?

    /// 图片落盘后的文件名（相对 images 目录）
    var imageFileName: String?
    /// 缩略图，最大边 400px，用于列表预览
    var thumbnailData: Data?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    /// 原图过大，只保留了缩略图
    var imageTruncated: Bool = false

    /// Vision OCR 结果：让截图/图片里的文字可被搜到。nil = 还没识别过，"" = 识别过但没文字
    var ocrText: String?

    /// 识别到的文字（去掉占位空白）。nil / 空白都表示"这张图里没识别出文字"
    var ocrRecognizedText: String {
        (ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否跑过识别。写库时没识别出文字会存一个空格，所以不能用 nil 判断
    var ocrAttempted: Bool { !(ocrText ?? "").isEmpty }

    var filePaths: [String] = []
    var fileNames: [String] = []

    /// 拼音索引，支持中文搜索
    var pinyinIndex: String?

    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// 来源 App 图标（捕获时快照存库，App 关掉后也能显示）
    var sourceAppIconData: Data?
    var copiedAt: Date = Date()
    var isPinned: Bool = false
    /// 内容指纹，重复复制只更新时间不新增条目
    var contentHash: String = ""
    var byteSize: Int = 0

    init(
        kind: ClipKind,
        textContent: String = "",
        rtfData: Data? = nil,
        contentHash: String,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.isImage = kind == .image
        self.textContent = textContent
        self.rtfData = rtfData
        self.contentHash = contentHash
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.copiedAt = Date()
        self.isPinned = false
        self.pinyinIndex = Pinyin.index(for: textContent)
    }
}

extension ClipItem {
    /// 列表展示用的一行预览（压成单行）
    var preview: String {
        switch kind {
        case .image:
            if imageTruncated { return "[大图片 \(imageWidth)×\(imageHeight)]" }
            if !textContent.isEmpty { return textContent }
            return "[图片 \(imageWidth)×\(imageHeight)]"
        case .file:
            if fileNames.count == 1 { return fileNames[0] }
            return "[\(fileNames.count) 个文件] \(fileNames.prefix(3).joined(separator: "、"))"
        case .color:
            return textContent
        case .text:
            return textContent
        }
    }

    var displayText: String {
        switch kind {
        case .image: return textContent.isEmpty ? preview : textContent
        default: return textContent
        }
    }
}
