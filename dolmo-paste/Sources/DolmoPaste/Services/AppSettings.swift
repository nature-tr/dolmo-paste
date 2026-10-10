import Combine
import Foundation

/// 全局设置。手写 UserDefaults 同步，方便服务层直接读（@AppStorage 只能在 View 里用）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let historyLimit = "historyLimit"
        static let imageLimit = "imageLimit"
        static let maxImageBytes = "maxImageBytes"
        static let ocrEnabled = "ocrEnabled"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let pasteDelayMs = "pasteDelayMs"
        static let autoPaste = "autoPaste"
        static let launchAtLogin = "launchAtLogin"
        static let panelStyle = "panelStyle"
    }

    private let defaults = UserDefaults.standard

    /// 文本类条目上限，超出淘汰最老的非 Pin 项
    @Published var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Key.historyLimit) }
    }
    /// 图片类条目上限（图片占空间，单独限流）
    @Published var imageLimit: Int {
        didSet { defaults.set(imageLimit, forKey: Key.imageLimit) }
    }
    /// 截图 OCR：识别图片里的文字，让截图可被搜到
    @Published var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: Key.ocrEnabled) }
    }
    /// 超过这个大小的图片只留缩略图（默认 10 MB）
    @Published var maxImageBytes: Int {
        didSet { defaults.set(maxImageBytes, forKey: Key.maxImageBytes) }
    }
    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Key.excludedBundleIDs) }
    }
    /// 写入剪贴板到模拟 ⌘V 之间的间隔，太短会粘空
    @Published var pasteDelayMs: Int {
        didSet { defaults.set(pasteDelayMs, forKey: Key.pasteDelayMs) }
    }
    /// 自动模拟 ⌘V（需要辅助功能权限）；关闭则只写回剪贴板
    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    /// 面板外观：系统样式 / dolmo design
    @Published var panelStyle: PanelStyleKind {
        didSet { defaults.set(panelStyle.rawValue, forKey: Key.panelStyle) }
    }

    private init() {
        let registered: [String: Any] = [
            Key.historyLimit: 500,
            Key.imageLimit: 200,
            Key.maxImageBytes: 10 * 1024 * 1024,
            Key.pasteDelayMs: 60,
            Key.autoPaste: true,
            Key.launchAtLogin: false,
            Key.ocrEnabled: false,
            Key.excludedBundleIDs: Array(Privacy.defaultExcludedApps.keys),
            Key.panelStyle: PanelStyleKind.system.rawValue,
        ]
        defaults.register(defaults: registered)

        historyLimit = defaults.integer(forKey: Key.historyLimit)
        imageLimit = defaults.integer(forKey: Key.imageLimit)
        maxImageBytes = defaults.integer(forKey: Key.maxImageBytes)
        pasteDelayMs = defaults.integer(forKey: Key.pasteDelayMs)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        panelStyle = PanelStyleKind(rawValue: defaults.string(forKey: Key.panelStyle) ?? "") ?? .system
        ocrEnabled = defaults.bool(forKey: Key.ocrEnabled)
        excludedBundleIDs = defaults.stringArray(forKey: Key.excludedBundleIDs) ?? Array(Privacy.defaultExcludedApps.keys)
    }

    var excludedBundleIDSet: Set<String> { Set(excludedBundleIDs) }
}
