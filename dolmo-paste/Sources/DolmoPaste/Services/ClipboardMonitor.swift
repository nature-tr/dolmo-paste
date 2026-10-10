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
            if let tiff = image.tiffRepresentation {
                captured.byteSize = tiff.count
                captured.hash = CapturedContent.hash(of: tiff)
            } else {
                captured.hash = CapturedContent.hash(of: captured.text)
            }
            content = captured
        }
        // 3. 文本
        else if let str = pasteboard.string(forType: .string), !str.isEmpty {
            var captured = CapturedContent(kind: .text)
            captured.text = str
            if let rtf = pasteboard.data(forType: .rtf) { captured.rtfData = rtf }
            captured.hash = CapturedContent.hash(of: str)
            captured.byteSize = str.utf8.count
            content = captured
        }

        guard let captured = content else { return }

        // 空剪贴板（只有 clearContents）不该记
        if captured.text.isEmpty && captured.image == nil && captured.fileURLs == nil { return }

        onCapture?(captured)
    }

    private func readImage() -> NSImage? {
        if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff) { return image }
        if let png = pasteboard.data(forType: .png), let image = NSImage(data: png) { return image }
        return nil
    }
}
