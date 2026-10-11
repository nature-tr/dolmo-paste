import AppKit
import SwiftData
import Vision

/// 历史仓库。图片一律落盘，SQLite 里只留路径；每次插入后强制淘汰，防止库无限膨胀。
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// 数据真正更新**之后**回调（objectWillChange 是"将要变更"，那时 items 还是旧值）。
    /// 观察者要靠它拿到更新后的行数，不能靠 objectWillChange 的时序。
    var onDidChange: (() -> Void)?

    private let container: ModelContainer
    private let context: ModelContext
    private let settings = AppSettings.shared

    let imagesDirectory: URL
    /// 片段库（常用片段，不参与淘汰）
    private(set) var snippetStore: SnippetStore!
    private static let thumbnailMaxEdge: CGFloat = 400

    /// - Parameter inMemory: 截图评审模式用，数据只在内存，不碰用户真实历史
    init(inMemory: Bool = false) throws {
        thumbnailCache.countLimit = Self.thumbnailCacheLimit
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
        // 片段和历史共用同一个库文件，但独立的表，不参与淘汰
        container = try ModelContainer(for: ClipItem.self, Snippet.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = true
        refresh()
        // 必须在任何 prune 之前：旧库没有 isImage 列，SwiftData 加列给的默认值是 false，
        // 不补的话老图片会被当成文本——图片永远淘汰不掉，文本那边还会误删图片
        backfillIsImage()
        snippetStore = SnippetStore(context: context)
    }

    /// 按 kind 补齐 isImage。只扫 isImage == false 的，补过之后再启动就只剩非图片了
    private func backfillIsImage() {
        let pending = FetchDescriptor<ClipItem>(predicate: #Predicate { !$0.isImage })
        guard let items = try? context.fetch(pending) else { return }
        var changed = false
        for item in items where item.kind == .image {
            item.isImage = true
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("dolmo-paste", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 查询

    // MARK: - 查询

    /// 首屏只取这么多条。上限能设到 5000，一次性全量 fetch 每条还带缩略图 blob，
    /// 常驻内存会是几百 MB，唤起面板明显卡。改成先取 200，滚到底再追加
    private static let pageSize = 200
    /// 已加载条数的硬上限。分页只加不卸，不设顶的话上限调到 5000 就会全量常驻内存
    /// （每条都带来源 App 图标 blob）。与其无限加载，不如提示用搜索缩小范围
    private static let maxLoadedCount = 1000
    private(set) var loadedCount = 0
    /// 上一次 fetch 取到的比 limit 少，说明已经到底了
    private var reachedEnd = false

    /// 还有没有没加载的（列表滚到底时用它决定要不要继续取）
    var hasMore: Bool {
        guard !reachedEnd else { return false }
        guard loadedCount < Self.maxLoadedCount else { return false }
        return loadedCount < settings.historyLimit + settings.imageLimit
    }

    /// 撞到加载上限、但库里其实还有更多。列表底部据此提示，而不是假装到底了
    var hasReachedLoadCap: Bool {
        !reachedEnd && loadedCount >= Self.maxLoadedCount
    }

    /// 加载上限，列表底部提示里要给用户看具体数字
    var loadCap: Int { Self.maxLoadedCount }

    func refresh() {
        // items 是 private(set)，外部改不了它，但删除/清除/淘汰后必须显式通知：
        // 否则清空历史、改小上限这类操作要等到下一次复制才刷新 UI
        objectWillChange.send()
        loadedCount = min(max(settings.historyLimit + settings.imageLimit, Self.pageSize), Self.pageSize)
        items = fetch(limit: loadedCount)
        reachedEnd = items.count < loadedCount
        thumbnailCache.removeAllObjects()
        onDidChange?()
    }

    /// 滚到底加载下一页
    func loadMore() {
        guard hasMore else { return }
        objectWillChange.send()
        loadedCount += Self.pageSize
        items = fetch(limit: loadedCount)
        reachedEnd = items.count < loadedCount
        onDidChange?()
    }

    private func fetch(limit: Int) -> [ClipItem] {
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 缩略图：按需读，不跟着条目一起常驻

    /// 缩略图缓存。用 NSCache 而不是字典：字典没有淘汰，滚一遍全部图片就都常驻了
    /// （400px 边长的 PNG 约 50–150KB，5000 张最坏几百 MB）。NSCache 还有内存压力时自动清的好处
    private let thumbnailCache = NSCache<NSString, NSData>()
    private static let thumbnailCacheLimit = 200

    /// 列表滚到哪读到哪。缩略图 blob 全部常驻是内存大头，改成按文件名惰性取
    func thumbnailData(for item: ClipItem) -> Data? {
        guard let name = item.imageFileName else { return item.thumbnailData }
        let key = name as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached as Data }
        let url = imagesDirectory.appendingPathComponent(name)
        let data = try? Data(contentsOf: url)
        if let data { thumbnailCache.setObject(data as NSData, forKey: key) }
        return data ?? item.thumbnailData
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

    /// 按当前上限淘汰。改小限额时要显式调一次，否则旧数据一直留到下次复制才清
    func prune() {
        let removedImages = pruneCategory(isImage: true, limit: settings.imageLimit)
        let removedOthers = pruneCategory(isImage: false, limit: settings.historyLimit)
        if removedImages || removedOthers {
            try? context.save()
            refresh()
        }
    }

    /// 淘汰某一类（图片 / 非图片）。
    ///
    /// 原来是**不带 fetchLimit 的全量 fetch**：每复制一次都要走一遍 prune，
    /// 上限设到 5000 时每复制一次就加载 5000 个对象（每个还带图标 blob）。
    /// 实测造 1010 条就把测试套件从 11s 拖到 39s。分两步：
    ///   1. `fetchCount` 判断是否超限 —— SQL COUNT，不加载对象，日常路径到这就结束了
    ///   2. 只有真要删时，才按时间正序取"最早的一小批"候选
    /// - Returns: 是否删过东西
    @discardableResult
    private func pruneCategory(isImage: Bool, limit: Int) -> Bool {
        guard limit > 0 else { return false }

        // 用 isImage（Bool）而不是 kind（enum）当查询键：enum 走不了 predicate
        let total: Int
        if isImage {
            total = (try? context.fetchCount(
                FetchDescriptor<ClipItem>(predicate: #Predicate { $0.isImage })
            )) ?? 0
        } else {
            total = (try? context.fetchCount(
                FetchDescriptor<ClipItem>(predicate: #Predicate { !$0.isImage })
            )) ?? 0
        }
        guard total > limit else { return false }
        let excess = total - limit

        // 最早的一批里可能混着固定项（删不掉），多取这些条才能保证筛完还够删
        let pinnedCount = (try? context.fetchCount(
            FetchDescriptor<ClipItem>(predicate: #Predicate { $0.isPinned })
        )) ?? 0
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .forward)])
        descriptor.fetchLimit = excess + pinnedCount
        let candidates = (try? context.fetch(descriptor)) ?? []

        var removed = 0
        for item in candidates where removed < excess {
            guard (item.kind == .image) == isImage, !item.isPinned else { continue }
            removeItem(item)
            removed += 1
        }
        return removed > 0
    }

    // MARK: - 孤儿图片回收

    /// 磁盘上有、但没有任何条目引用的图片文件名。
    /// 淘汰/删除都走 removeItem 会删文件，但异常退出、进程被杀时会留下孤儿，
    /// 日积月累是纯浪费的磁盘占用。这里只算不删，方便测试
    func orphanImageNames() -> [String] {
        guard let all = try? context.fetch(FetchDescriptor<ClipItem>()) else { return [] }
        let referenced = Set(all.compactMap { $0.imageFileName })
        // 缩略图存不进库、退化成内存 blob 的条目没有文件名，但它们也没占磁盘，不用管
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        return contents.filter { name in
            // 只认我们自己写的 .png，目录里万一有别的东西不能动
            guard name.hasSuffix(".png") else { return false }
            return !referenced.contains(name)
        }
    }

    /// - Returns: 删掉的文件数
    @discardableResult
    func pruneOrphanImages() -> Int {
        let orphans = orphanImageNames()
        guard !orphans.isEmpty else { return 0 }
        for name in orphans {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
        return orphans.count
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
                // 批量：每张只写属性，末尾统一保存 + 刷新一次。
                // 原来每张都 save + refresh（各 fetch 数百条并触发 UI 重绘），200 张会卡很久
                await MainActor.run { self.applyOCR(text, to: id, refresh: false) }
            }
            await MainActor.run {
                try? self.context.save()
                self.refresh()
            }
        }
    }

    /// 写回结果。识别失败也写 ""，下次启动就不会重复扫同一张
    private func applyOCR(_ text: String?, to id: PersistentIdentifier, refresh: Bool = true) {
        applyOCRResult(text, to: id)
        if refresh {
            try? context.save()
            self.refresh()
        }
    }

    /// 只写属性，不保存也不刷新。批量回填时用它，最后统一落盘
    private func applyOCRResult(_ text: String?, to id: PersistentIdentifier) {
        guard let item = context.model(for: id) as? ClipItem else { return }
        // 没识别出文字也写一个空格标记：SwiftData 里 NULL 和空串都读成 ""，
        // 不标记的话这些图每次启动都会被重扫一遍
        let result = text ?? ""
        item.ocrText = result.isEmpty ? " " : result
        if !result.isEmpty, item.pinyinIndex?.isEmpty != false {
            item.pinyinIndex = Pinyin.index(for: result)
        }
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
