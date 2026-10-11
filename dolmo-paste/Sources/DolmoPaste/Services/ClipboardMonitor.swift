import AppKit
import CryptoKit

/// 一次捕获到的原始内容，落盘之前的中间态
struct CapturedContent {
    var kind: ClipKind
    var text: String = ""
    var rtfData: Data?
    var image: NSImage?
    var fileURLs: [URL]?
    var hash: String = ""
    var byteSize: Int = 0

    static func hash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(of text: String) -> String {
        hash(of: Data(text.utf8))
    }
}

/// 剪贴板监听。
///
/// macOS 没有剪贴板变更通知 API，只能轮询 changeCount。
/// 单次开销约 10 微秒（一次 Mach IPC 取整数），0.5 秒间隔基本等于零成本。
@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressCount = 0

    var onCapture: ((CapturedContent) -> Void)?
    var excludedBundleIDs: Set<String> { AppSettings.shared.excludedBundleIDSet }

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        let interval = 0.5
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 自己写剪贴板时调用，避免把自己粘出去的内容记成新条目
    func suppressNextChange(_ count: Int = 1) {
        suppressCount += count
    }

    /// 写回剪贴板之后调用：直接把基线对齐到当前值。
    /// 比计数更稳，因为 clearContents + write 会产生多次变化。
    func skipChangesUpToNow() {
        lastChangeCount = pasteboard.changeCount
        suppressCount = 0
    }

    private func tick() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if suppressCount > 0 {
            suppressCount -= 1
            return
        }

        // Electron 系应用一次复制会 clear + write 多次，防抖拿最终态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.read()
        }
    }

    private func read() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier

        guard Privacy.shouldStore(pasteboard, excludedBundleIDs: excludedBundleIDs, currentBundleID: bundleID) else {
            return
        }
        guard let types = pasteboard.types, !types.isEmpty else { return }

        var content: CapturedContent?

        // 1. 文件
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            var captured = CapturedContent(kind: .file)
            captured.fileURLs = urls
            captured.text = urls.map(\.path).joined(separator: "\n")
            captured.hash = CapturedContent.hash(of: captured.text)
            captured.byteSize = captured.text.utf8.count
            content = captured
        }
        // 2. 图片
        else if let image = readImage() {
            var captured = CapturedContent(kind: .image)
            captured.image = image
            if let str = pasteboard.string(forType: .string) { captured.text = str }
            // 指纹优先用剪贴板里已有的 PNG：整图 TIFF 是未压缩 RGBA，
            // 一张 6000×4000 的截图约 96MB，在主线程算会卡死好几秒
            if let png = pngDataInPasteboard() {
                captured.hash = CapturedContent.hash(of: png)
                captured.byteSize = png.count
            } else {
                // 只有 TIFF 时退回到尺寸估算 + 缩略图指纹，绝不碰整图位图
                let w = image.size.width, h = image.size.height
                captured.byteSize = Int(w * h * 4)
                captured.hash = CapturedContent.hash(of: "\(w)x\(h)-\(captured.text.hashValue)")
            }
            content = captured
        }
        // 3. 颜色值：设计工具复制的多是纯 hex，按文本存会看不出是什么颜色
        else if let str = pasteboard.string(forType: .string), let hex = ContentHeuristics.normalizedHex(str) {
            var captured = CapturedContent(kind: .color)
            captured.text = hex
            captured.hash = CapturedContent.hash(of: hex)
            captured.byteSize = hex.utf8.count
            content = captured
        }
        // 4. HTML：网页/邮件复制的内容，只存纯文本会丢掉链接和排版，转成 RTF 一起存。
        //    解析不出文本就往下走，按普通文本处理，别把这次捕获丢掉
        else if let html = pasteboard.data(forType: .html), !html.isEmpty,
                let plain = ContentHeuristics.plainText(fromHTML: html), !plain.isEmpty {
            var captured = CapturedContent(kind: .text)
            captured.text = ContentHeuristics.capped(plain)
            captured.rtfData = ContentHeuristics.rtf(fromHTML: html)
            captured.hash = CapturedContent.hash(of: html)
            captured.byteSize = html.count
            content = captured
        }
        // 5. 文本
        else if let str = pasteboard.string(forType: .string), !str.isEmpty {
            var captured = CapturedContent(kind: .text)
            // 复制几百 MB 日志/JSON 时不能全量入库：库会膨胀到 GB，主线程也会卡住。
            // 超上限只留前缀，指纹仍按完整内容算，重复复制不会被当成新条目
            captured.text = ContentHeuristics.capped(str)
            if let rtf = pasteboard.data(forType: .rtf), rtf.count <= ContentHeuristics.maxTextBytes { captured.rtfData = rtf }
            captured.hash = CapturedContent.hash(of: str)
            captured.byteSize = str.utf8.count
            content = captured
        }

        guard let captured = content else { return }

        // 空剪贴板（只有 clearContents）不该记
        if captured.text.isEmpty && captured.image == nil && captured.fileURLs == nil { return }

        onCapture?(captured)
    }

    /// 剪贴板自带的 PNG（各 App 复制图片时基本都提供），拿来做指纹最省
    private func pngDataInPasteboard() -> Data? {
        pasteboard.data(forType: .png)
    }

    private func readImage() -> NSImage? {
        if let png = pasteboard.data(forType: .png), let image = NSImage(data: png) { return image }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff) { return image }
        return nil
    }
}
