import AppKit
import SwiftData
import Vision

/// 历史仓库。图片一律落盘，SQLite 里只留路径；每次插入后强制淘汰，防止库无限膨胀。
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    private let container: ModelContainer
    private let context: ModelContext
    private let settings = AppSettings.shared

    let imagesDirectory: URL
    private static let thumbnailMaxEdge: CGFloat = 400

    /// - Parameter inMemory: 截图评审模式用，数据只在内存，不碰用户真实历史
    init(inMemory: Bool = false) throws {
        let configuration: ModelConfiguration
        if inMemory {
            imagesDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dolmo-snapshot-images", isDirectory: true)
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let support = try Self.applicationSupportDirectory()
            imagesDirectory = support.appendingPathComponent("images", isDirectory: true)
            configuration = ModelConfiguration(url: support.appendingPathComponent("dolmo-paste.store"))
        }
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        container = try ModelContainer(for: ClipItem.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = true
        refresh()
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("dolmo-paste", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 查询

    func refresh() {
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        descriptor.fetchLimit = settings.historyLimit + settings.imageLimit + 64
        items = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 写入

    func add(_ content: CapturedContent) {
        let frontmost = NSWorkspace.shared.frontmostApplication

        // 重复复制：不新增条目，把旧的顶上来
        if let existing = findByHash(content.hash) {
            existing.copiedAt = Date()
            existing.sourceAppBundleID = frontmost?.bundleIdentifier
            existing.sourceAppName = frontmost?.localizedName
            if let icon = frontmost?.icon,
               existing.sourceAppIconData == nil || (existing.sourceAppIconData?.count ?? 0) > 50_000 {
                existing.sourceAppIconData = Self.iconPNG(of: icon)
            }
            try? context.save()
            refresh()
            return
        }

        let item = ClipItem(
            kind: content.kind,
            textContent: content.text,
            rtfData: content.rtfData,
            contentHash: content.hash,
            sourceAppBundleID: frontmost?.bundleIdentifier,
            sourceAppName: frontmost?.localizedName
        )
        item.byteSize = content.byteSize
        if let icon = frontmost?.icon {
            item.sourceAppIconData = Self.iconPNG(of: icon)
        }

        switch content.kind {
        case .image:
            if let image = content.image {
                let stored = persistImage(image, truncatedLimit: settings.maxImageBytes)
                item.imageFileName = stored.fileName
                item.thumbnailData = stored.thumbnail
                item.imageWidth = stored.width
                item.imageHeight = stored.height
                item.imageTruncated = stored.truncated
            }
        case .file:
            if let urls = content.fileURLs {
                item.filePaths = urls.map(\.path)
                item.fileNames = urls.map { $0.lastPathComponent }
            }
        default:
            break
        }

        context.insert(item)
        try? context.save()
        prune()
        refresh()

        if settings.ocrEnabled, content.kind == .image {
            recognizeAndStore(itemID: item.persistentModelID, fileName: item.imageFileName, image: content.image)
        }
    }

    private func findByHash(_ hash: String) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate<ClipItem> { $0.contentHash == hash },
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - 图片落盘

    private struct StoredImage {
        var fileName: String?
        var thumbnail: Data?
        var width: Int
        var height: Int
        var truncated: Bool
    }

    private func persistImage(_ image: NSImage, truncatedLimit: Int) -> StoredImage {
        let size = image.size
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let thumbnail = Self.pngData(of: Self.resized(image, maxEdge: Self.thumbnailMaxEdge))

        guard let fullData = Self.pngData(of: image) else {
            return StoredImage(fileName: nil, thumbnail: thumbnail, width: width, height: height, truncated: true)
        }

        // 大图只留缩略图：库里不塞 MB 级 blob，粘贴时降级但条目不丢
        guard fullData.count <= truncatedLimit else {
            return StoredImage(fileName: nil, thumbnail: thumbnail, width: width, height: height, truncated: true)
        }

        let fileName = "\(UUID().uuidString).png"
        let url = imagesDirectory.appendingPathComponent(fileName)
        do {
            try fullData.write(to: url)
            return StoredImage(fileName: fileName, thumbnail: thumbnail, width: width, height: height, truncated: false)
        } catch {
            return StoredImage(fileName: nil, thumbnail: thumbnail, width: width, height: height, truncated: true)
        }
    }

    /// App 图标专用。
    /// 不能直接用 NSImage.size 判断——NSWorkspace 给的图标是 32pt 但内嵌 1024px 的 representation，
    /// 按 size 缩放会原样返回，PNG 出来能有几 MB。这里强制按像素重绘。
    static func iconPNG(of image: NSImage, pixelSize: CGFloat = 32) -> Data? {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let best = reps.sorted { lhs, rhs in
            abs(lhs.pixelsWide - Int(pixelSize)) < abs(rhs.pixelsWide - Int(pixelSize))
        }.first

        let base: NSImage
        if let best, let cgImage = best.cgImage {
            base = NSImage(cgImage: cgImage, size: NSSize(width: best.pixelsWide, height: best.pixelsHigh))
        } else {
            base = image
        }

        let target = NSSize(width: pixelSize, height: pixelSize)
        let result = NSImage(size: target)
        result.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1.0)
        result.unlockFocus()

        guard let tiff = result.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func pngData(of image: NSImage?) -> Data? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func resized(_ image: NSImage, maxEdge: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxEdge / max(size.width, size.height), 1.0)
        guard scale < 1.0 else { return image }
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let result = NSImage(size: target)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        result.unlockFocus()
        return result
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    // MARK: - 淘汰

    /// 只删数据不刷新列表，批量删除（prune/clearAll）内部用，最后统一 save + refresh
    private func removeItem(_ item: ClipItem) {
        if let name = item.imageFileName {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
        context.delete(item)
    }

    private func prune() {
        let descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        guard let all = try? context.fetch(descriptor) else { return }

        var changed = false
        let images = all.filter { $0.kind == .image }
        let others = all.filter { $0.kind != .image }

        if images.count > settings.imageLimit {
            let removable = images.filter { !$0.isPinned }
            let excess = images.count - settings.imageLimit
            for victim in removable.suffix(min(excess, removable.count)) {
                removeItem(victim)
                changed = true
            }
        }

        if others.count > settings.historyLimit {
            let removable = others.filter { !$0.isPinned }
            let excess = others.count - settings.historyLimit
            for victim in removable.suffix(min(excess, removable.count)) {
                removeItem(victim)
                changed = true
            }
        }
        if changed {
            try? context.save()
            refresh()
        }
    }

    // MARK: - 操作

    func togglePin(_ item: ClipItem) {
        item.isPinned.toggle()
        try? context.save()
        refresh()
    }

    func delete(_ item: ClipItem) {
        if let name = item.imageFileName {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
        context.delete(item)
        try? context.save()
        refresh()
    }

    func delete(_ items: [ClipItem]) {
        for item in items { delete(item) }
        refresh()
    }

    func clearAll(includePinned: Bool = false) {
        for item in items {
            if item.isPinned && !includePinned { continue }
            removeItem(item)
        }
        try? context.save()
        refresh()
    }

    // MARK: - 统计

    struct StorageStats {
        var total: Int = 0
        var images: Int = 0
        var pinned: Int = 0
        var files: Int = 0
        var imageBytes: Int64 = 0
        var oldest: Date?
        var newest: Date?
    }

    func stats() -> StorageStats {
        var result = StorageStats()
        result.total = items.count
        result.images = items.filter { $0.kind == .image }.count
        result.files = items.filter { $0.kind == .file }.count
        result.pinned = items.filter { $0.isPinned }.count
        result.newest = items.first?.copiedAt
        result.oldest = items.last?.copiedAt

        var bytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: imagesDirectory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
                bytes += Int64(size)
            }
        }
        result.imageBytes = bytes
        return result
    }

    // MARK: - 截图评审用的样例数据

    /// 直接插入一条构造好的记录（不走捕获流程、不淘汰），仅截图模式使用
    func insertSample(_ item: ClipItem, image: NSImage? = nil) {
        if let image {
            let stored = persistImage(image, truncatedLimit: .max)
            item.imageFileName = stored.fileName
            item.thumbnailData = stored.thumbnail
            item.imageWidth = stored.width
            item.imageHeight = stored.height
        }
        context.insert(item)
        try? context.save()
        refresh()
    }

    // MARK: - 图标回填

    private static var iconCache: [String: Data?] = [:]

    static func cachedIcon(bundleID: String) -> Data? {
        if let hit = iconCache[bundleID] { return hit }
        let result: Data?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            result = iconPNG(of: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            result = nil
        }
        iconCache[bundleID] = result
        return result
    }

    /// 升级前捕获的记录没有图标，启动时补一次；顺带把尺寸异常的图标重新生成
    func backfillIcons(limit: Int = 300) {
        guard let all = try? context.fetch(FetchDescriptor<ClipItem>()) else { return }
        let targets = all
            .filter {
                $0.sourceAppBundleID != nil &&
                ($0.sourceAppIconData == nil || ($0.sourceAppIconData?.count ?? 0) > 50_000)
            }
            .prefix(limit)

        var changed = false
        for item in targets {
            guard let bundleID = item.sourceAppBundleID,
                  let data = Self.cachedIcon(bundleID: bundleID) else { continue }
            item.sourceAppIconData = data
            changed = true
        }
        if changed {
            try? context.save()
            refresh()
        }
    }

    // MARK: - OCR（本地 Vision，不联网；让截图里的文字可被搜到）

    /// 新捕获的图片：后台识别完再回填。
    /// 有落盘原图就用原图（清晰）；大图只留了缩略图时退而用内存里的原图
    private func recognizeAndStore(itemID: PersistentIdentifier, fileName: String?, image: NSImage?) {
        let directory = imagesDirectory
        Task.detached(priority: .utility) {
            let text: String?
            if let fileName {
                text = Self.recognizeText(at: directory.appendingPathComponent(fileName))
            } else if let image {
                text = Self.recognizeText(in: image)
            } else {
                return
            }
            await MainActor.run { self.applyOCR(text, to: itemID) }
        }
    }

    /// 开关打开后补识别已有的图片。之前"开了没反应"就出在这：只对开关之后的新截图生效
    func backfillOCR(limit: Int = 200) {
        guard settings.ocrEnabled else { return }
        let pending = items
            .filter { $0.kind == .image && !$0.ocrAttempted && $0.imageFileName != nil }
            .prefix(limit)
            .map { ($0.persistentModelID, $0.imageFileName ?? "") }
        guard !pending.isEmpty else { return }
        let directory = imagesDirectory
        Task.detached(priority: .background) {
            for (id, fileName) in pending {
                let text = Self.recognizeText(at: directory.appendingPathComponent(fileName))
                await MainActor.run { self.applyOCR(text, to: id) }
            }
        }
    }

    /// 写回结果。识别失败也写 ""，下次启动就不会重复扫同一张
    private func applyOCR(_ text: String?, to id: PersistentIdentifier) {
        guard let item = context.model(for: id) as? ClipItem else { return }
        // 没识别出文字也写一个空格标记：SwiftData 里 NULL 和空串都读成 ""，
        // 不标记的话这些图每次启动都会被重扫一遍
        let result = text ?? ""
        item.ocrText = result.isEmpty ? " " : result
        if !result.isEmpty, item.pinyinIndex?.isEmpty != false {
            item.pinyinIndex = Pinyin.index(for: result)
        }
        try? context.save()
        refresh()
    }

    nonisolated private static func recognizeText(at url: URL) -> String? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return recognizeText(in: image)
    }

    nonisolated private static func recognizeText(in image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        // 开语言校正：中文长句断字会明显少一些
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        // 按位置从上到下、从左到右排：VN 返回的顺序是乱的，直接拼出来读不通
        let sorted = observations.sorted { lhs, rhs in
            let ly = 1 - lhs.boundingBox.midY
            let ry = 1 - rhs.boundingBox.midY
            if abs(ly - ry) > 0.01 { return ly < ry }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        // 丢掉低置信度的碎片，否则界面上的图标、水印会变成一堆乱码进索引
        let lines = sorted.compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.3 else { return nil }
            return candidate.string
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
